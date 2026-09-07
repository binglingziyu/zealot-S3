# frozen_string_literal: true

module Uploads
  class Multipart
    MAX_SIZE = 20 * 1024**3
    PART_SIZE = 16 * 1024**2
    MAX_PARTS_PER_REQUEST = 100
    ACTIVE_STATES = %w[initiated uploading].freeze

    def self.initiate(user:, channel:, filename:, byte_size:, idempotency_key:, sha256: nil, kind: 'package', metadata: {})
      raise ArgumentError, 'Uploads are disabled during recovery' if ENV['ZEALOT_RECOVERY_MODE'] == 'true'
      raise Pundit::NotAuthorizedError unless Access::AppAccess.allowed?(user, channel.app, action: :upload)
      raise ArgumentError, 'Application is archived' if channel.app.archived?
      size = Integer(byte_size)
      raise ArgumentError, 'File size must be between 1 byte and 20 GiB' unless size.between?(1, MAX_SIZE)
      raise ArgumentError, 'Unsupported upload kind' unless %w[package debug].include?(kind)
      name = File.basename(filename.to_s.tr('\\', '/'))
      raise ArgumentError, 'Invalid filename' if name.blank? || name.match?(/[\x00-\x1f]/) || name.bytesize > 255
      digest = sha256.presence&.downcase
      raise ArgumentError, 'Invalid SHA256' if digest && !digest.match?(/\A[0-9a-f]{64}\z/)
      key = idempotency_key.to_s
      raise ArgumentError, 'Idempotency key is required (max 200 characters)' if key.blank? || key.size > 200

      UploadSession.transaction do
        # Serialize retries for this user/key before creating either DB or S3 state.
        lock = Digest::SHA256.hexdigest("upload:#{user.id}:#{key}")[0, 15].to_i(16)
        UploadSession.connection.execute("SELECT pg_advisory_xact_lock(#{lock})")
        existing = UploadSession.find_by(user: user, idempotency_key: key)
        if existing
          unless existing.channel_id == channel.id && existing.expected_size == size && existing.expected_sha256 == digest && existing.stored_object.filename == name && existing.stored_object.kind == kind
            raise ArgumentError, 'Idempotency key was used for a different upload'
          end
          return existing
        end
        profile = channel.app.effective_storage_profile
        object = StoredObject.create!(storage_profile: profile, app: channel.app,
          key: profile.key("objects/#{SecureRandom.uuid}#{File.extname(name)}"), filename: name, kind: kind)
        UploadSession.create!(user: user, app: channel.app, channel: channel, stored_object: object,
          idempotency_key: key, expected_size: size, expected_sha256: digest,
          part_size: PART_SIZE, expires_at: 24.hours.from_now,
          metadata: metadata.to_h.stringify_keys.slice('changelog', 'source', 'branch', 'git_commit', 'ci_url', 'release_type', 'release_version', 'build_version'))
      end
    end

    def initialize(session, actor:)
      @session, @actor = session, actor
    end

    def sign_parts(numbers)
      @session.with_lock do
        authorize!
        raise ArgumentError, 'Upload has expired' if @session.expires_at <= Time.current
        raise ArgumentError, 'Upload is no longer accepting parts' unless ACTIVE_STATES.include?(@session.state)
        raise ArgumentError, 'Storage is disabled for new uploads' unless profile.enabled?
        parts = Array(numbers).map { |n| Integer(n) }.uniq
        max_part = (@session.expected_size.to_f / @session.part_size).ceil
        unless parts.any? && parts.size <= MAX_PARTS_PER_REQUEST && parts.all? { |n| n.between?(1, max_part) }
          raise ArgumentError, 'Invalid part numbers'
        end
        unless @session.multipart_upload_id
          result = client.create_multipart_upload(bucket: profile.bucket, key: object.key, content_type: object.content_type)
          @session.update!(multipart_upload_id: result.upload_id, state: 'uploading')
        end
        signer = Aws::S3::Presigner.new(client: profile.client(download: true))
        parts.map do |number|
          offset = (number - 1) * @session.part_size
          size = [@session.part_size, @session.expected_size - offset].min
          { part_number: number, byte_size: size, url: signer.presigned_url(:upload_part,
            bucket: profile.bucket, key: object.key, upload_id: @session.multipart_upload_id,
            part_number: number, content_length: size, expires_in: [900, (@session.expires_at - Time.current).to_i].min) }
        end
      end
    end

    def complete
      @session.with_lock do
        authorize!
        return @session if %w[uploaded verifying parsing ready].include?(@session.state)
        raise ArgumentError, 'Upload is no longer accepting completion' unless ACTIVE_STATES.include?(@session.state)
        raise ArgumentError, 'Upload has expired' if @session.expires_at <= Time.current
        raise ArgumentError, 'No upload parts have been requested' unless @session.multipart_upload_id
        begin
          parts = client.list_parts(bucket: profile.bucket, key: object.key, upload_id: @session.multipart_upload_id).flat_map(&:parts)
          expected_count = (@session.expected_size.to_f / @session.part_size).ceil
          valid = parts.size == expected_count && parts.each_with_index.all? do |part, index|
            part.part_number == index + 1 && part.size == [@session.part_size, @session.expected_size - index * @session.part_size].min
          end
          raise ArgumentError, 'Upload is incomplete or part sizes do not match' unless valid
          client.complete_multipart_upload(bucket: profile.bucket, key: object.key, upload_id: @session.multipart_upload_id,
            multipart_upload: { parts: parts.map { |part| { part_number: part.part_number, etag: part.etag } } })
        rescue Aws::S3::Errors::NoSuchUpload
          # A prior request may have completed S3 but lost its DB transaction.
          # Only our server can complete this upload, and the final key is unique.
        end
        head = client.head_object(bucket: profile.bucket, key: object.key)
        raise ArgumentError, 'Stored size does not match the upload session' unless head.content_length == @session.expected_size
        object.update!(state: 'uploaded', byte_size: head.content_length, etag: head.etag)
        @session.update!(state: 'uploaded', heartbeat_at: Time.current, error_message: nil)
        @session
      end
    end

    def uploaded_parts
      @session.with_lock do
        authorize!
        return [] unless ACTIVE_STATES.include?(@session.state) && @session.multipart_upload_id
        client.list_parts(bucket: profile.bucket, key: object.key, upload_id: @session.multipart_upload_id).flat_map(&:parts).map do |part|
          { part_number: part.part_number, byte_size: part.size, etag: part.etag }
        end
      rescue Aws::S3::Errors::NoSuchUpload
        # Completion may have reached the cloud before its database commit.
        # The completion endpoint reconciles this case through HEAD.
        complete
        []
      end
    end

    def cancel
      @session.with_lock do
        authorize!
        return @session if @session.state_cancelled?
        raise ArgumentError, 'Completed upload cannot be cancelled' unless ACTIVE_STATES.include?(@session.state)
        if @session.multipart_upload_id
          begin
            client.abort_multipart_upload(bucket: profile.bucket, key: object.key, upload_id: @session.multipart_upload_id)
          rescue Aws::S3::Errors::NoSuchUpload
          end
        end
        @session.update!(state: 'cancelled')
        object.retire!
        @session
      end
    end

    private

    def authorize!
      raise ArgumentError, 'Uploads are disabled during recovery' if ENV['ZEALOT_RECOVERY_MODE'] == 'true'
      unless @actor && (@actor.id == @session.user_id || @actor.admin?) && Access::AppAccess.allowed?(@actor, @session.app, action: :upload) && @session.upload_allowed?
        raise Pundit::NotAuthorizedError, 'Upload session is not accessible'
      end
    end

    def object
      @session.stored_object
    end

    def profile
      object.storage_profile
    end

    def client
      @client ||= profile.client
    end
  end
end
