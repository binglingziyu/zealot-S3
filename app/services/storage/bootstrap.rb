# frozen_string_literal: true

module Storage
  # Explicit, rerunnable deployment operation; never changes cloud objects.
  class Bootstrap
    def self.preview
      {
        apps_without_group: App.where(group_id: nil).count,
        releases_without_object: Release.where(package_object_id: nil).where.not(file: [nil, '']).count,
        debug_files_without_object: DebugFile.where(stored_object_id: nil).where.not(file: [nil, '']).count,
        legacy_global_developers: User.developers.count
      }
    end

    def self.call
      profile = import_default!
      ApplicationRecord.transaction do
        group = Group.find_or_create_by!(name: '未分组')
        App.where(group_id: nil).update_all(group_id: group.id)
        # Preserve existing global developers' access to EXISTING apps only.
        # Future apps require explicit group or application membership.
        User.developers.find_each do |user|
          App.find_each do |app|
            membership = Collaborator.find_or_initialize_by(user: user, app: app)
            membership.role = :developer if membership.new_record? || membership.member?
            membership.owner = false if membership.owner.nil?
            membership.save! if membership.changed?
          end
        end
      end
      Release.find_each do |release|
        attach!(release, :package_object_id, release.file, 'package', profile)
        attach!(release, :icon_object_id, release.icon, 'icon', profile)
      end
      DebugFile.find_each { |debug| attach!(debug, :stored_object_id, debug.file, 'debug', profile) }
      profile
    end

    def self.import_default!
      StorageProfile.find_by(system_default: true) || StorageProfile.create! do |profile|
        profile.name = 'Imported default storage'
        profile.provider = ENV.fetch('ZEALOT_S3_ENDPOINT', '').include?('r2.cloudflarestorage.com') ? 'r2' : 's3'
        profile.region = ENV.fetch('ZEALOT_S3_REGION', 'us-east-1')
        profile.bucket = ENV.fetch('ZEALOT_S3_BUCKET')
        profile.endpoint = ENV['ZEALOT_S3_ENDPOINT'].presence
        profile.download_endpoint = ENV['ZEALOT_S3_DOWNLOAD_ENDPOINT'].presence
        profile.public_download_origin = ENV['ZEALOT_S3_PUBLIC_DOWNLOAD_ORIGIN'].presence
        profile.prefix = Zealot::Storage::S3.prefix
        profile.force_path_style = ENV['ZEALOT_S3_FORCE_PATH_STYLE'] == 'true'
        profile.url_expires_in = Zealot::Storage::S3.expires_in
        profile.system_default = true
        if ENV['ZEALOT_S3_ACCESS_KEY_ID'].present?
          profile.credentials = {
            access_key_id: ENV.fetch('ZEALOT_S3_ACCESS_KEY_ID'),
            secret_access_key: ENV.fetch('ZEALOT_S3_SECRET_ACCESS_KEY'),
            session_token: ENV['ZEALOT_S3_SESSION_TOKEN']
          }
        end
      end
    end

    def self.attach!(record, attribute, uploader, kind, profile)
      return if record[attribute].present? || uploader.identifier.blank?

      key = profile.key(uploader.store_path(uploader.identifier))
      # Fail on missing/inaccessible objects instead of silently mapping bad data.
      head = profile.client.head_object(bucket: profile.bucket, key: key)
      record.with_lock do
        return if record[attribute].present?
        object = StoredObject.find_or_initialize_by(storage_profile: profile, key: key)
        if object.persisted? && object.app_id != record.app.id
          raise ArgumentError, 'Legacy object belongs to another application'
        end
        object.assign_attributes(
          app: record.app, filename: uploader.identifier, kind: kind, state: 'ready',
          byte_size: head.content_length, content_type: head.content_type || 'application/octet-stream',
          etag: head.etag, sha256: head.metadata['sha256']
        )
        object.save!
        record.update_columns(attribute => object.id)
      end
    end
    private_class_method :attach!
  end
end
