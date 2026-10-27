# frozen_string_literal: true

module Zealot
  module Storage
    # Preserves the local uploads layout for migration and portable backups.
    class Transfer
      def self.export_to(directory, app_ids: nil)
        client = S3.client
        prefix = "#{S3.key('uploads')}/"
        client.list_objects_v2(bucket: S3.bucket, prefix: prefix).each do |page|
          page.contents.each do |object|
            relative = object.key.delete_prefix(prefix)
            next if relative.end_with?('/')
            next if app_ids && !relative.match?(%r{\A(?:apps|debug_files)/a(?:#{app_ids.map { |id| Integer(id) }.join('|')})/})
            raise ArgumentError, 'Unsafe S3 object path' if relative.split('/').any? { |part| part == '..' || part == '.' || part.empty? }

            target = ::File.join(directory, relative)
            FileUtils.mkdir_p(::File.dirname(target))
            client.get_object(bucket: S3.bucket, key: object.key, response_target: target)
          end
        end
      end

      def self.import_from(directory)
        client = S3.client
        Dir.glob(::File.join(directory, '**', '*')).sort.each do |path|
          next unless ::File.file?(path)
          raise ArgumentError, 'Symlink in upload archive' if ::File.symlink?(path)

          relative = Pathname.new(path).relative_path_from(Pathname.new(directory)).to_s
          object = S3::File.new("uploads/#{relative}", client: client)
          local = CarrierWave::SanitizedFile.new(path)
          object.store!(local)
          remote = client.head_object(bucket: S3.bucket, key: object.key)
          digest = Digest::SHA256.new
          client.get_object(bucket: S3.bucket, key: object.key) { |chunk| digest.update(chunk) }
          unless remote.content_length == ::File.size(path) && digest.hexdigest == Digest::SHA256.file(path).hexdigest
            raise IOError, "S3 verification failed for #{relative}"
          end
        end
      end
    end
  end
end
