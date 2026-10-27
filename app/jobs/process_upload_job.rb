# frozen_string_literal: true

class ProcessUploadJob < ApplicationJob
  queue_as :app_parse

  def perform(id)
    return if ENV['ZEALOT_RECOVERY_MODE'] == 'true'
    return unless UploadSession.where(state: %w[uploaded verifying parsing failed]).exists?(id: id)
    Uploads::ParserProcess.new(id).call
  rescue Uploads::ParserProcess::Busy
    self.class.set(wait: 30.seconds).perform_later(id)
  end

  def perform_isolated(id, claim_path: nil)
    return if ENV['ZEALOT_RECOVERY_MODE'] == 'true'
    UploadSession.connection_pool.with_connection do |connection|
      lock = Digest::SHA256.hexdigest("parse:#{id}")[0, 15].to_i(16)
      return unless connection.select_value("SELECT pg_try_advisory_lock(#{lock})")
      begin
        process(id, claim_path: claim_path)
      ensure
        connection.execute("SELECT pg_advisory_unlock(#{lock})")
      end
    end
  end

  def self.fail_isolated(id, message, claim:)
    UploadSession.connection_pool.with_connection do |connection|
      lock = Digest::SHA256.hexdigest("parse:#{id}")[0, 15].to_i(16)
      return unless connection.select_value("SELECT pg_try_advisory_lock(#{lock})")
      begin
        session = UploadSession.find_by(id: id)
        return unless session
        session.with_lock do
          # Never overwrite a later attempt, a finished result or an expired task.
          eligible = claim ? (%w[verifying parsing].include?(session.state) && session.attempts == claim) : session.state_uploaded?
          return unless eligible
          session.update!(state: 'failed', error_message: message.truncate(1000),
            attempts: claim ? session.attempts : session.attempts + 1, heartbeat_at: Time.current)
        end
      ensure
        connection.execute("SELECT pg_advisory_unlock(#{lock})")
      end
    end
  end

  private

  def process(id, claim_path: nil)
    session = UploadSession.find_by(id: id)
    return unless session
    session.with_lock do
      return unless %w[uploaded verifying parsing failed].include?(session.state)
      raise Pundit::NotAuthorizedError, 'Upload permission was revoked' unless session.upload_allowed?
      raise ArgumentError, 'Object is no longer available' if session.stored_object.state_deleted? || session.stored_object.state_purged?
      session.update!(state: 'verifying', attempts: session.attempts + 1, heartbeat_at: Time.current, error_message: nil)
      File.write(claim_path, session.attempts.to_s, mode: 'w', perm: 0o600) if claim_path
    end
    object = session.stored_object
    object.with_local_file(expected_size: session.expected_size) do |path|
      raise ArgumentError, 'Object size changed' unless File.size(path) == session.expected_size
      sha256 = Digest::SHA256.file(path).hexdigest
      raise ArgumentError, 'SHA256 mismatch' if session.expected_sha256 && session.expected_sha256 != sha256
      Uploads::ArchiveGuard.check!(path)
      object.update!(sha256: sha256, byte_size: File.size(path))
      session.update!(state: 'parsing', heartbeat_at: Time.current)
      if object.kind == 'package'
        publish_package(session, object, path)
      else
        publish_debug(session, object, path)
      end
    end
  rescue StandardError => error
    if session&.persisted? && !session.reload.state_ready?
      session.update_columns(state: 'failed', error_message: "#{error.class.name}: #{error.message}".truncate(1000), heartbeat_at: Time.current, updated_at: Time.current)
    end
    Rails.logger.warn("Direct upload #{id} failed: #{error.class.name}")
  end

  def publish_package(session, object, path)
    parser = begin
      AppInfo.parse(path)
    rescue AppInfo::UnknownFormatError
      raise unless %w[linux windows].include?(session.channel.device_type)
      nil
    end
    session.with_lock do
      raise Pundit::NotAuthorizedError unless session.upload_allowed?
      return if session.release_id
      session.channel.lock!
      release = session.channel.releases.new(session.metadata.slice('changelog', 'source', 'branch', 'git_commit', 'ci_url', 'release_type', 'release_version', 'build_version'))
      release.package_object = object
      release[:file] = object.filename
      release.parse_direct!(parser) if parser
      if parser && %w[android ios].include?(session.channel.device_type) && release.platform.downcase != session.channel.device_type
        raise ArgumentError, 'Package platform does not match the channel'
      end
      object.update!(state: 'ready')
      release.save!
      TeardownService.new(path, release: release, user: session.user).call if parser
      session.update!(state: 'ready', release: release, heartbeat_at: Time.current)
      session.channel.perform_web_hook('upload_events', session.user_id, release: release)
      AuditEvent.record!(user: session.user, action: 'upload.published', subject: release, details: { upload_session_id: session.id })
    end
  ensure
    parser&.clear! if parser&.respond_to?(:clear!)
  end

  def publish_debug(session, object, path)
    session.with_lock do
      raise Pundit::NotAuthorizedError unless session.upload_allowed?
      return if session.debug_file_id
      debug = DebugFile.new(app: session.app, stored_object: object,
        device_type: session.channel.device_type,
        **session.metadata.slice('release_version', 'build_version').symbolize_keys)
      debug[:file] = object.filename
      object.update!(state: 'ready')
      debug.save!
      DebugFileTeardownJob.perform_now(debug, session.user_id, strict: true)
      raise ArgumentError, 'Debug archive could not be parsed' unless debug.persisted? && debug.metadata.exists?
      session.update!(state: 'ready', debug_file: debug, heartbeat_at: Time.current)
      AuditEvent.record!(user: session.user, action: 'upload.published', subject: debug, details: { upload_session_id: session.id })
    end
  end
end
