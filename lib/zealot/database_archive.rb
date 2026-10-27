# frozen_string_literal: true

require 'aws-sdk-s3'
require 'json'
require 'digest'
require 'tmpdir'
require 'securerandom'
require 'time'

module Zealot
  # No Rails/database connection is needed to discover or download a backup.
  class DatabaseArchive
    attr_reader :client, :bucket, :prefix, :database

    def initialize(client:, bucket:, prefix:, database:)
      @client, @bucket, @prefix, @database = client, bucket, prefix.sub(%r{/+\z}, ''), database.transform_keys(&:to_s)
      raise ArgumentError, 'A safe backup prefix is required' if @prefix.empty? || @prefix.start_with?('/') || @prefix.split('/').any? { |part| ['', '.', '..'].include?(part) }
    end

    def dump
      Dir.mktmpdir('zealot-db-backup-') do |directory|
        path = File.join(directory, 'database.dump')
        execute('pg_dump', '--format=custom', '--no-owner', '--no-acl', '--file', path)
        File.chmod(0o600, path)
        key = "#{prefix}/#{Time.now.utc.strftime('%Y%m%dT%H%M%SZ')}-#{SecureRandom.uuid}.dump"
        manifest = { 'format' => 1, 'key' => key, 'size' => File.size(path),
          'sha256' => Digest::SHA256.file(path).hexdigest, 'created_at' => Time.now.utc.iso8601,
          'database' => database.fetch('database'), 'image_ref' => ENV['ZEALOT_VCS_REF'] }
        Aws::S3::TransferManager.new(client: client).upload_file(path, bucket: bucket, key: key)
        verify_object!(key, manifest)
        client.put_object(bucket: bucket, key: "#{key}.json", body: JSON.generate(manifest), content_type: 'application/json')
        manifest
      end
    end

    def list
      client.list_objects_v2(bucket: bucket, prefix: "#{prefix}/").flat_map do |page|
        page.contents.filter_map { |entry| read_manifest(entry.key) if entry.key.end_with?('.dump.json') }
      end.sort_by { |manifest| manifest.fetch('created_at') }.reverse
    end

    def read_manifest(key)
      raise ArgumentError, 'Manifest is outside the backup prefix' unless key.start_with?("#{prefix}/") && key.end_with?('.dump.json')
      json = +''
      client.get_object(bucket: bucket, key: key) do |chunk|
        raise ArgumentError, 'Backup manifest is too large' if json.bytesize + chunk.bytesize > 16_384
        json << chunk
      end
      manifest = JSON.parse(json)
      unless manifest['format'] == 1 && manifest['key'] == key.delete_suffix('.json') &&
          manifest['size'].is_a?(Integer) && manifest['size'].positive? && manifest['sha256'].to_s.match?(/\A[0-9a-f]{64}\z/)
        raise ArgumentError, 'Invalid backup manifest'
      end
      manifest
    end

    def restore(manifest_key, target:)
      raise ArgumentError, 'Recovery mode is required' unless ENV['ZEALOT_RECOVERY_MODE'] == 'true'
      raise ArgumentError, 'An explicit database name, not a connection string, is required' unless target.to_s.match?(/\A[a-zA-Z0-9_][a-zA-Z0-9_.-]*\z/)
      manifest = read_manifest(manifest_key)
      Dir.mktmpdir('zealot-db-restore-') do |directory|
        path = File.join(directory, 'database.dump')
        bytes = 0
        digest = Digest::SHA256.new
        File.open(path, File::WRONLY | File::CREAT | File::EXCL, 0o600) do |file|
          client.get_object(bucket: bucket, key: manifest.fetch('key')) do |chunk|
            bytes += chunk.bytesize
            raise IOError, 'Archive exceeds its recorded size' if bytes > manifest.fetch('size')
            digest.update(chunk)
            file.write(chunk)
          end
        end
        raise IOError, 'Backup checksum/size mismatch' unless bytes == manifest['size'] && digest.hexdigest == manifest['sha256']
        execute('pg_restore', '--clean', '--if-exists', '--no-owner', '--no-acl', '--exit-on-error', '--single-transaction', '--dbname', target, path)
      end
      manifest
    end

    def delete(manifest, retention_days:)
      raise ArgumentError, 'Backup is inside its recovery window' if Time.iso8601(manifest.fetch('created_at')) > Time.now - retention_days * 86_400
      key = manifest.fetch('key')
      raise ArgumentError, 'Archive is outside backup prefix' unless key.start_with?("#{prefix}/")
      client.delete_object(bucket: bucket, key: "#{key}.json")
      client.delete_object(bucket: bucket, key: key)
    end

    private

    def verify_object!(key, manifest)
      digest = Digest::SHA256.new
      bytes = 0
      client.get_object(bucket: bucket, key: key) { |chunk| bytes += chunk.bytesize; digest.update(chunk) }
      raise IOError, 'Remote backup verification failed' unless bytes == manifest['size'] && digest.hexdigest == manifest['sha256']
    end

    def execute(*command)
      mapping = { 'host' => 'PGHOST', 'port' => 'PGPORT', 'username' => 'PGUSER', 'password' => 'PGPASSWORD',
        'database' => 'PGDATABASE', 'sslmode' => 'PGSSLMODE', 'sslrootcert' => 'PGSSLROOTCERT', 'sslcert' => 'PGSSLCERT', 'sslkey' => 'PGSSLKEY' }
      environment = mapping.to_h { |key, variable| [variable, database[key]&.to_s] }
      # Child-only environment: never change process-wide credentials between jobs.
      pid = Process.spawn(environment, *command, in: File::NULL, out: File::NULL, err: File::NULL)
      _, status = Process.waitpid2(pid)
      raise IOError, "#{command.first} failed (#{status})" unless status.success?
    end
  end
end
