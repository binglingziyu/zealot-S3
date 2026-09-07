# frozen_string_literal: true
module Storage
  class Reconciler
    GRACE = 2.days

    def initialize(profile, now: Time.current)
      @profile, @now = profile, now
    end

    def call
      return if ENV['ZEALOT_RECOVERY_MODE'] == 'true'
      StorageProfile.connection_pool.with_connection do |connection|
        lock = Digest::SHA256.hexdigest("storage-reconcile:#{@profile.id}")[0, 15].to_i(16)
        return unless connection.select_value("SELECT pg_try_advisory_lock(#{lock})")
        begin
          reconcile_multipart
          reconcile_objects
          retire_unreferenced
        ensure
          connection.execute("SELECT pg_advisory_unlock(#{lock})")
        end
      end
    end

    private

    def client
      @client ||= @profile.client
    end

    def prefix
      @profile.key('objects/')
    end

    def managed_key?(key)
      key.match?(%r{\A#{Regexp.escape(prefix)}[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}(?:\.[^/]+)?\z}i)
    end

    def reconcile_multipart
      count = scan_multipart(prefix)
      return unless count.zero?
      # MinIO intentionally does not implement prefix-wide multipart listing.
      # Direct-upload object keys are committed before initiating S3, so exact
      # key lookups can recover a lost upload ID on these providers.
      @profile.stored_objects.where.not(state: 'purged').where('created_at < ?', @now - GRACE).find_each do |object|
        scan_multipart(object.key) if managed_key?(object.key)
      end
    end

    def scan_multipart(object_prefix)
      count = 0
      client.list_multipart_uploads(bucket: @profile.bucket, prefix: object_prefix).each do |page|
        page.uploads.each do |upload|
          count += 1
          next unless managed_key?(upload.key) && upload.initiated < @now - GRACE
          # A different profile may point to the same bucket. Never abort an ID
          # known anywhere in the database, even if this profile didn't create it.
          next if UploadSession.exists?(multipart_upload_id: upload.upload_id)
          # Some compatible providers return a different opaque ID representation
          # from ListMultipartUploads than CreateMultipartUpload. An active key
          # is therefore protected independently of the upload ID representation.
          next if UploadSession.where(stored_object_id: StoredObject.where(key: upload.key).select(:id))
            .where.not(state: %w[ready failed expired cancelled]).exists?
          client.abort_multipart_upload(bucket: @profile.bucket, key: upload.key, upload_id: upload.upload_id)
          AuditEvent.record!(user: nil, action: 'storage.orphan_multipart.abort', subject: @profile, details: { key: upload.key })
        rescue Aws::S3::Errors::NoSuchUpload
          # Another reconciliation or completion already consumed the upload.
        end
      end
      count
    end

    def reconcile_objects
      client.list_objects_v2(bucket: @profile.bucket, prefix: prefix).each do |page|
        page.contents.each do |entry|
          next unless managed_key?(entry.key) && entry.last_modified < @now - GRACE
          next if StoredObject.exists?(key: entry.key)
          # Cloud writes cannot roll back with SQL. Record a tombstone for a
          # surviving cloud object, then give it a full database recovery window.
          StoredObject.transaction do
            key_lock = Digest::SHA256.hexdigest("orphan-object:#{entry.key}")[0, 15].to_i(16)
            StoredObject.connection.execute("SELECT pg_advisory_xact_lock(#{key_lock})")
            next if StoredObject.exists?(key: entry.key)
            object = StoredObject.create!(storage_profile: @profile, key: entry.key,
              filename: File.basename(entry.key), kind: 'package', byte_size: entry.size, etag: entry.etag)
            object.retire!
            AuditEvent.record!(user: nil, action: 'storage.orphan_object.retire', subject: object)
          end
        rescue ActiveRecord::RecordNotUnique
          # A writer committed its object reference while the listing was read.
        rescue ActiveRecord::RecordInvalid
          raise unless StoredObject.exists?(key: entry.key)
        end
      end
    end

    def retire_unreferenced
      @profile.stored_objects.where(state: %w[pending uploaded ready]).where('updated_at < ?', @now - GRACE).find_each do |object|
        object.with_lock do
          next if object.retained_reference? || object.upload_sessions.exists?
          object.retire!
        end
      end
    end
  end
end
