# frozen_string_literal: true

module Backups
  class RemoteDatabase
    def initialize(backup)
      @backup = backup
      @profile = backup.storage_profile || StorageProfile.find_by!(system_default: true)
      raise ArgumentError, 'Database backups require a separate private bucket' if @profile.public_bucket?
    end

    def archive
      @archive ||= Zealot::DatabaseArchive.new(client: @profile.client, bucket: @profile.bucket,
        prefix: @profile.key("database-backups/#{@backup.id}"), database: ActiveRecord::Base.connection_db_config.configuration_hash)
    end

    def call
      raise ArgumentError, 'Backups are disabled during recovery' if ENV['ZEALOT_RECOVERY_MODE'] == 'true'
      manifest = @backup.with_lock do
        @backup.update!(storage_profile: @profile) unless @backup.storage_profile_id
        @profile.with_lock do
          manifest = archive.dump
          StoredObject.create!(storage_profile: @profile, kind: 'backup', key: manifest.fetch('key'),
            filename: File.basename(manifest.fetch('key')), state: 'ready', byte_size: manifest.fetch('size'), sha256: manifest.fetch('sha256'))
          manifest
        end
      end
      begin
        prune
      rescue StandardError => error
        Rails.logger.warn("Backup #{@backup.id} retention cleanup: #{error.class.name}")
      end
      manifest
    end

    def files
      archive.list.map { |manifest| RemoteFile.new(manifest, @profile) }
    end

    def delete(filename)
      file = files.find { |item| item.basename == filename.to_s }
      raise ActiveRecord::RecordNotFound unless file
      archive.delete(file.manifest, retention_days: retention_days)
      StoredObject.where(storage_profile: @profile, key: file.manifest.fetch('key')).update_all(state: 'purged', updated_at: Time.current)
    end

    private

    def retention_days
      [Integer(ENV.fetch('ZEALOT_DATABASE_RETENTION_DAYS', '30')), 1].max
    end

    def prune
      return if @backup.max_keeps.negative?
      archive.list.drop([@backup.max_keeps, 1].max).each do |manifest|
        next if Time.iso8601(manifest.fetch('created_at')) > retention_days.days.ago
        archive.delete(manifest, retention_days: retention_days)
        StoredObject.where(storage_profile: @profile, key: manifest.fetch('key')).update_all(state: 'purged', updated_at: Time.current)
      end
    end

    class RemoteFile
      attr_reader :manifest
      def initialize(manifest, profile)
        @manifest, @profile = manifest, profile
      end
      def basename = File.basename(manifest.fetch('key'))
      alias name basename
      alias shortname basename
      def size = manifest.fetch('size')
      def sha256 = manifest.fetch('sha256')
      def created_at = Time.iso8601(manifest.fetch('created_at'))
      def url
        Aws::S3::Presigner.new(client: @profile.client(download: true)).presigned_url(:get_object,
          bucket: @profile.bucket, key: manifest.fetch('key'), expires_in: 300,
          response_content_disposition: ActionDispatch::Http::ContentDisposition.format(disposition: 'attachment', filename: basename))
      end
    end
  end
end
