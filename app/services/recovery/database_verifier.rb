# frozen_string_literal: true

module Recovery
  class DatabaseVerifier
    def self.call
      raise ArgumentError, 'Recovery mode is required' unless ENV['ZEALOT_RECOVERY_MODE'] == 'true'
      raise ArgumentError, 'Workers must be external during recovery' unless GoodJob.configuration.execution_mode == :external
      # A restored job queue is never authoritative about external side effects.
      WebHookDelivery.suppress_before!(Time.current)
      GoodJob::Execution.delete_all
      GoodJob::Job.delete_all
      Rails.cache.clear
      checked = 0
      missing = []
      StoredObject.where(id: Release.select(:package_object_id))
        .or(StoredObject.where(id: Release.select(:icon_object_id)))
        .or(StoredObject.where(id: DebugFile.select(:stored_object_id))).find_each do |object|
        profile = object.storage_profile
        head = profile.client.head_object(bucket: profile.bucket, key: object.key)
        if object.byte_size && head.content_length != object.byte_size
          missing << object.id
        else
          checked += 1
        end
      rescue Aws::S3::Errors::NotFound, Aws::S3::Errors::NoSuchKey
        missing << object.id
      end
      raise IOError, "Restore references missing or changed objects: #{missing.join(', ')}" if missing.any?
      unbound = Release.where(package_object_id: nil).count + DebugFile.where(stored_object_id: nil).count
      raise IOError, "Restore contains #{unbound} unbound package/debug records; finish legacy bootstrap before opening service" if unbound.positive?
      AuditEvent.create!(action: 'database.restore.verified', subject_type: 'Database',
        subject_id: ActiveRecord::Base.connection_db_config.database, details: { objects: checked })
      { objects: checked, notifications_suppressed: true, old_jobs_removed: true }
    end
  end
end
