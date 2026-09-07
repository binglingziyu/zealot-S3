# frozen_string_literal: true

class ReconcileUploadsJob < ApplicationJob
  queue_as :schedule

  def perform
    return if ENV['ZEALOT_RECOVERY_MODE'] == 'true'
    UploadSession.where(state: %w[uploaded verifying parsing]).where('heartbeat_at IS NULL OR heartbeat_at < ?', 15.minutes.ago).find_each do |session|
      ProcessUploadJob.perform_later(session.id)
    end
    # Failed tasks retry a bounded number of times. Manual retry remains available.
    UploadSession.where(state: 'failed').where('attempts < 3 AND heartbeat_at < ?', 5.minutes.ago).find_each do |session|
      ProcessUploadJob.perform_later(session.id) if session.upload_allowed?
    end
    UploadSession.where(state: %w[initiated uploading]).where('expires_at < ?', 1.hour.ago).find_each do |session|
      session.with_lock do
        next unless %w[initiated uploading].include?(session.state)
        profile = session.stored_object.storage_profile
        if session.multipart_upload_id
          begin
            profile.client.abort_multipart_upload(bucket: profile.bucket, key: session.stored_object.key, upload_id: session.multipart_upload_id)
          rescue Aws::S3::Errors::NoSuchUpload
          end
        end
        session.stored_object.retire!
        session.update_columns(state: 'expired', updated_at: Time.current)
      end
    end
  end
end
