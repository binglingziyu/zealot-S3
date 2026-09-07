# frozen_string_literal: true

require 'aws-sdk-s3'
require 'carrierwave/storage/abstract'
require 'tempfile'
require 'digest'

module Zealot
  module Storage
    # CarrierWave keeps its staging cache local. Only successfully stored objects
    # use S3; parsers explicitly materialize temporary local copies when needed.
    class S3 < CarrierWave::Storage::Abstract
      def self.enabled?
        ENV.fetch('ZEALOT_STORAGE', 'file') == 's3'
      end

      def self.bucket
        ENV.fetch('ZEALOT_S3_BUCKET')
      end

      def self.prefix
        ENV.fetch('ZEALOT_S3_PREFIX', '').sub(%r{\A/+}, '').sub(%r{/+\z}, '')
      end

      def self.key(path)
        [prefix, path].reject(&:empty?).join('/')
      end

      def self.expires_in
        value = Integer(ENV.fetch('ZEALOT_S3_URL_EXPIRES_IN', '3600'))
        raise ArgumentError, 'ZEALOT_S3_URL_EXPIRES_IN must be 1..604800' unless (1..604800).cover?(value)

        value
      end

      def self.client(download: false)
        options = {
          region: ENV.fetch('ZEALOT_S3_REGION', 'us-east-1'),
          force_path_style: ENV.fetch('ZEALOT_S3_FORCE_PATH_STYLE', 'false') == 'true',
          retry_limit: 3,
          http_open_timeout: 10,
          http_read_timeout: 120,
          request_checksum_calculation: 'when_required',
          response_checksum_validation: 'when_required'
        }
        endpoint = if download
          ENV['ZEALOT_S3_DOWNLOAD_ENDPOINT'].presence || ENV['ZEALOT_S3_ENDPOINT'].presence
        else
          ENV['ZEALOT_S3_ENDPOINT'].presence
        end
        options[:endpoint] = endpoint if endpoint
        if ENV['ZEALOT_S3_ACCESS_KEY_ID'].present?
          options[:credentials] = Aws::Credentials.new(
            ENV.fetch('ZEALOT_S3_ACCESS_KEY_ID'), ENV.fetch('ZEALOT_S3_SECRET_ACCESS_KEY'),
            ENV['ZEALOT_S3_SESSION_TOKEN']
          )
        end
        Aws::S3::Client.new(options)
      end

      def store!(file)
        object = File.new(uploader.store_path, client: self.class.client)
        object.store!(file)
        object
      end

      def retrieve!(identifier)
        File.new(uploader.store_path(identifier), client: self.class.client)
      end

      class File
        attr_reader :path, :client

        def initialize(path, client: S3.client)
          @path = path
          @client = client
        end

        def key
          S3.key(path)
        end

        def filename
          ::File.basename(path)
        end

        def store!(file)
          # SDK upload_file streams and switches to multipart for large packages.
          Aws::S3::Object.new(bucket_name: S3.bucket, key: key, client: client).upload_file(
            file.path, content_type: file.content_type || 'application/octet-stream',
            metadata: { 'sha256' => Digest::SHA256.file(file.path).hexdigest }
          )
          @head = nil
        end

        def exists?
          head
          true
        rescue Aws::S3::Errors::NotFound, Aws::S3::Errors::NoSuchKey
          false
        end

        def size
          head.content_length
        rescue Aws::S3::Errors::NotFound, Aws::S3::Errors::NoSuchKey
          0
        end

        def content_type
          head.content_type
        end

        def empty?
          size.zero?
        end

        def read
          client.get_object(bucket: S3.bucket, key: key).body.read
        end

        def delete
          client.delete_object(bucket: S3.bucket, key: key)
          @head = nil
        end

        def url(options = {})
          params = { bucket: S3.bucket, key: key, expires_in: S3.expires_in }
          params[:response_content_disposition] = options[:disposition] if options[:disposition]
          Aws::S3::Presigner.new(client: S3.client(download: true)).presigned_url(:get_object, params)
        end

        def with_local_file
          Tempfile.create(['zealot-s3-', ::File.extname(path)], Rails.root.join('tmp')) do |tmp|
            tmp.binmode
            client.get_object(bucket: S3.bucket, key: key, response_target: tmp.path)
            yield tmp.path
          end
        end

        private

        def head
          @head ||= client.head_object(bucket: S3.bucket, key: key)
        end
      end
    end
  end
end
