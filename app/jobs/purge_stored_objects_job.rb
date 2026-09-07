# frozen_string_literal: true

class PurgeStoredObjectsJob < ApplicationJob
  queue_as :schedule

  def perform
    return if ENV['ZEALOT_RECOVERY_MODE'] == 'true'
    StoredObject.where(state: 'deleted').where('purge_after < ?', Time.current).find_each do |object|
      object.with_lock do
        next unless object.state_deleted? && object.purge_after && object.purge_after < Time.current
        # References in the restored/current DB always win over a deletion queue.
        next if Release.where(package_object_id: object.id).or(Release.where(icon_object_id: object.id)).exists?
        next if DebugFile.where(stored_object_id: object.id).exists?
        next if object.upload_sessions.where.not(state: %w[cancelled expired failed ready]).exists?
        profile = object.storage_profile
        profile.client.delete_object(bucket: profile.bucket, key: object.key)
        object.update!(state: 'purged')
      end
    end
  end
end
