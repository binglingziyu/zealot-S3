# frozen_string_literal: true

module Storage
  class ObjectMover
    def self.start!(source_id:, target_profile_id:, actor:)
      authorize!(actor)
      ObjectMigration.transaction do
        source = StoredObject.lock.find(source_id)
        target_profile = StorageProfile.find(target_profile_id)
        raise ArgumentError, 'Choose a different enabled storage profile' unless target_profile.enabled? && source.storage_profile_id != target_profile.id
        # Repeated operator requests reuse the same pending/completed task.
        existing = ObjectMigration.where(source_object: source,
          target_object_id: StoredObject.where(storage_profile: target_profile).select(:id)).where.not(state: 'cancelled').first
        return existing if existing
        eligible_source!(source)
        target = StoredObject.create!(storage_profile: target_profile, app: source.app, kind: source.kind,
          filename: source.filename, key: target_profile.key("objects/#{SecureRandom.uuid}#{File.extname(source.filename)}"))
        migration = ObjectMigration.create!(source_object: source, target_object: target, user: actor)
        AuditEvent.record!(user: actor, action: 'storage.migration.created', subject: migration)
        migration
      end
    end

    def self.authorize!(actor)
      raise ArgumentError, 'Migration is disabled during recovery' if ENV['ZEALOT_RECOVERY_MODE'] == 'true'
      actor = User.find_by(id: actor.id) if actor
      raise Pundit::NotAuthorizedError unless actor&.admin? && actor.active_for_authentication?
    end

    def self.eligible_source!(source)
      raise ArgumentError, 'Only published application objects can be migrated' unless source.state_ready? && source.app && source.kind != 'backup'
      raise ArgumentError, 'An upload still uses this object' if source.upload_sessions.where.not(state: %w[ready expired cancelled]).exists?
    end

    def self.run(id)
      migration = ObjectMigration.find(id)
      authorize!(migration.user)
      ObjectMigration.connection_pool.with_connection do |connection|
        key = Digest::SHA256.hexdigest("object-migration:#{migration.source_object_id}")[0, 15].to_i(16)
        return unless connection.select_value("SELECT pg_try_advisory_lock(#{key})")
        begin
          new(migration).run
        ensure
          connection.execute("SELECT pg_advisory_unlock(#{key})")
        end
      end
    end

    def initialize(migration)
      @migration = migration
      @source, @target = migration.source_object, migration.target_object
    end

    def run
      @migration.with_lock do
        return if @migration.state_complete? || @migration.state_cancelled?
        self.class.eligible_source!(@source.reload)
        raise ArgumentError, 'Destination was purged; create a new migration' if @target.reload.state_purged?
        @migration.update!(state: 'copying', attempts: @migration.attempts + 1, error_class: nil)
      end
      @source.with_local_file do |path|
        digest = Digest::SHA256.file(path).hexdigest
        size = File.size(path)
        raise IOError, 'Source checksum mismatch' if @source.sha256 && @source.sha256 != digest
        profile = @target.storage_profile
        unless target_verified?(profile, size, digest)
          Aws::S3::TransferManager.new(client: profile.client).upload_file(path, bucket: profile.bucket, key: @target.key)
          raise IOError, 'Destination verification failed' unless target_verified?(profile, size, digest)
        end
        switch_references!(size, digest)
      end
    rescue StandardError => error
      @migration.with_lock do
        unless @migration.state_complete? || @migration.state_cancelled?
          @migration.update!(state: 'failed', error_class: error.class.name)
        end
      end
      raise
    end

    private

    def target_verified?(profile, size, digest)
      return false unless profile.client.head_object(bucket: profile.bucket, key: @target.key).content_length == size
      received = 0
      actual = Digest::SHA256.new
      profile.client.get_object(bucket: profile.bucket, key: @target.key) do |chunk|
        received += chunk.bytesize
        raise IOError, 'Destination size changed during verification' if received > size
        actual.update(chunk)
      end
      received == size && actual.hexdigest == digest
    rescue Aws::S3::Errors::NotFound, Aws::S3::Errors::NoSuchKey
      false
    end

    def switch_references!(size, digest)
      @migration.with_lock do
        raise ArgumentError, 'Migration was cancelled' unless @migration.state_copying?
        self.class.authorize!(@migration.user)
        # Match deletion lock order: release/debug rows precede stored objects.
        Release.where(package_object_id: @source.id).or(Release.where(icon_object_id: @source.id)).order(:id).lock.load
        DebugFile.where(stored_object_id: @source.id).order(:id).lock.load
        @source.lock!
        @target.lock!
        self.class.eligible_source!(@source)
        @target.update!(state: 'ready', byte_size: size, sha256: digest, deleted_at: nil, purge_after: nil)
        Release.where(package_object_id: @source.id).update_all(package_object_id: @target.id)
        Release.where(icon_object_id: @source.id).update_all(icon_object_id: @target.id)
        DebugFile.where(stored_object_id: @source.id).update_all(stored_object_id: @target.id)
        @source.retire!
        @migration.update!(state: 'complete', error_class: nil)
        AuditEvent.record!(user: @migration.user, action: 'storage.migration.completed', subject: @migration,
          details: { source_object_id: @source.id, target_object_id: @target.id })
      end
    end
  end
end
