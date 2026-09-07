require 'fastlane/action'
require 'zealot_direct/client'

module Fastlane
  module Actions
    module SharedValues
      %i[ZEALOT_APP_ID ZEALOT_RELEASE_ID ZEALOT_RELEASE_URL ZEALOT_QRCODE_URL ZEALOT_INSTALL_URL ZEAALOT_ERROR_MESSAGE].each do |key|
        const_set(key, key) unless const_defined?(key, false)
      end
    end
    class ZealotDirectUploadAction < Action
      def self.run(params)
        file = params[:file] || Actions.lane_context[:IPA_OUTPUT_PATH] || Actions.lane_context[:GRADLE_APK_OUTPUT_PATH]
        UI.user_error!('Provide file or run gym/gradle before zealot_direct_upload') unless file
        result = ::ZealotDirect::Client.new(endpoint: params[:endpoint], token: params[:token],
          verify_ssl: params[:verify_ssl], request_timeout: params[:timeout], wait_timeout: params[:wait_timeout], concurrency: params[:concurrency],
          progress: ->(part, total) { UI.message("Uploaded part #{part}/#{total}") }).upload(
            file: file, channel_key: params[:channel_key], kind: params[:kind],
            idempotency_key: params[:idempotency_key], changelog: params[:changelog], source: 'fastlane',
            release_version: params[:release_version], build_version: params[:build_version])
        ENV['ZEALOT_RELEASE_URL'] = result['release_url'].to_s
        ENV['ZEALOT_INSTALL_URL'] = result['install_url'].to_s
        %w[app_id release_id release_url qrcode_url install_url].each do |key|
          Actions.lane_context["ZEALOT_#{key.upcase}".to_sym] = result[key]
        end
        Actions.lane_context[:ZEAALOT_ERROR_MESSAGE] = nil
        UI.success('Zealot analysis completed')
        result
      rescue ::ZealotDirect::Error => error
        Actions.lane_context[:ZEAALOT_ERROR_MESSAGE] = error.message
        UI.user_error!(error.message)
      end

      def self.available_options
        [
          FastlaneCore::ConfigItem.new(key: :endpoint, env_name: 'ZEALOT_ENDPOINT', description: 'Zealot server origin', type: String),
          FastlaneCore::ConfigItem.new(key: :token, env_name: 'ZEALOT_TOKEN', description: 'Zealot user or service token', type: String, sensitive: true),
          FastlaneCore::ConfigItem.new(key: :channel_key, env_name: 'ZEALOT_CHANNEL_KEY', description: 'Target channel', type: String),
          FastlaneCore::ConfigItem.new(key: :file, env_name: 'ZEALOT_FILE', description: 'APK, IPA or debug archive path', optional: true, type: String),
          FastlaneCore::ConfigItem.new(key: :kind, description: 'package or debug', default_value: 'package', type: String),
          FastlaneCore::ConfigItem.new(key: :changelog, description: 'Release notes', optional: true, type: String),
          FastlaneCore::ConfigItem.new(key: :release_version, description: 'Debug archive release version', optional: true, type: String),
          FastlaneCore::ConfigItem.new(key: :build_version, description: 'Debug archive build version', optional: true, type: String),
          FastlaneCore::ConfigItem.new(key: :idempotency_key, description: 'Stable CI upload identifier', optional: true, type: String),
          FastlaneCore::ConfigItem.new(key: :verify_ssl, description: 'Verify Zealot TLS certificate', default_value: true, type: Fastlane::Boolean),
          FastlaneCore::ConfigItem.new(key: :timeout, description: 'Request timeout in seconds', default_value: 600, type: Integer),
          FastlaneCore::ConfigItem.new(key: :concurrency, description: 'Concurrent storage part uploads (1-8)', default_value: 3, type: Integer),
          FastlaneCore::ConfigItem.new(key: :wait_timeout, description: 'Analysis timeout in seconds', default_value: 1800, type: Integer)
        ]
      end

      def self.description
        'Upload directly to object storage, then wait for Zealot to verify and publish'
      end

      def self.authors
        ['Zealot S3 contributors']
      end

      def self.is_supported?(_platform)
        true
      end
    end
  end
end
