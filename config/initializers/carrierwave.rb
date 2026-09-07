# frozen_string_literal: true

require_relative '../../lib/zealot/storage/s3'
require_relative '../../lib/zealot/storage/transfer'

Rails.application.config.filter_parameters += [:ticket]

storage = ENV.fetch('ZEALOT_STORAGE', 'file')
raise ArgumentError, 'ZEALOT_STORAGE must be file or s3' unless %w[file s3].include?(storage)
if storage == 's3'
  raise ArgumentError, 'ZEALOT_S3_BUCKET is required' if ENV['ZEALOT_S3_BUCKET'].blank?
  Zealot::Storage::S3.expires_in
end

Rails.configuration.to_prepare do
  CarrierWave.configure do |config|
    url_options = Setting.url_options
    config.asset_host = "#{url_options[:protocol]}#{url_options[:host]}"
    config.cache_dir = Rails.root.join('tmp', 'uploads', Rails.env)
  end
end
