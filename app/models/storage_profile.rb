# frozen_string_literal: true

require 'aws-sdk-s3'
require 'uri'

# A profile fixes an object location. Create a new profile to move buckets;
# rotating its encrypted credentials does not change existing object references.
class StorageProfile < ApplicationRecord
  LOCATION_FIELDS = %w[region endpoint download_endpoint public_download_origin bucket prefix force_path_style].freeze
  has_many :stored_objects, dependent: :restrict_with_error
  has_many :apps, dependent: :restrict_with_error
  has_many :groups, dependent: :restrict_with_error
  has_many :storage_grants, dependent: :destroy
  has_many :backups, dependent: :restrict_with_error

  validates :name, presence: true, uniqueness: true, length: { maximum: 150 }
  validates :bucket, :region, presence: true
  validates :provider, inclusion: { in: %w[s3 r2 minio oss] }
  validates :url_expires_in, numericality: { only_integer: true, greater_than: 0, less_than_or_equal_to: 604800 }
  validate :valid_endpoints
  validate :immutable_location
  validate :valid_prefix

  def credentials=(values)
    normalized = values.to_h.stringify_keys.slice('access_key_id', 'secret_access_key', 'session_token')
    raise ArgumentError, 'Access key and secret are required' if normalized.values_at('access_key_id', 'secret_access_key').any?(&:blank?)

    self.credentials_ciphertext = self.class.encryptor.encrypt_and_sign(normalized.to_json)
    self.credentials_version = credentials_version.to_i + 1 if persisted?
  end

  def credentials
    return {} if credentials_ciphertext.blank?

    JSON.parse(self.class.encryptor.decrypt_and_verify(credentials_ciphertext))
  end

  def self.encryptor
    # SECRET_KEY_BASE must survive a database restore and remain outside the DB.
    key = Rails.application.key_generator.generate_key('zealot-storage-credentials-v1', 32)
    ActiveSupport::MessageEncryptor.new(key, cipher: 'aes-256-gcm')
  end

  def key(relative)
    [prefix.presence, relative.sub(%r{\A/+}, '')].compact.join('/')
  end

  def client(download: false)
    options = {
      region: region, force_path_style: force_path_style, retry_limit: 3,
      http_open_timeout: 10, http_read_timeout: 120,
      request_checksum_calculation: 'when_required', response_checksum_validation: 'when_required'
    }
    target = download ? download_endpoint.presence || endpoint.presence : endpoint.presence
    options[:endpoint] = target if target
    secrets = credentials
    if secrets.present?
      options[:credentials] = Aws::Credentials.new(secrets.fetch('access_key_id'), secrets.fetch('secret_access_key'), secrets['session_token'])
    end
    Aws::S3::Client.new(options)
  end

  def public_url(key)
    return if public_download_origin.blank?

    escaped_key = key.split('/').map { |part| ERB::Util.url_encode(part).gsub('+', '%20') }.join('/')
    "#{public_download_origin.chomp('/')}/#{escaped_key}"
  end

  def public_bucket?
    public_download_origin.present? || self.class.where(bucket: bucket, endpoint: endpoint)
      .where.not(public_download_origin: [nil, '']).exists?
  end

  def available_for?(app)
    enabled? && (system_default? || (app.id && storage_grants.where(app_id: app.id).exists?) ||
      (app.group_id && storage_grants.where(group_id: app.group_id).exists?))
  end

  # Never serialize credentials through generic API serializers or audit events.
  def serializable_hash(options = nil)
    super((options || {}).merge(except: Array(options&.dig(:except)) + ['credentials_ciphertext']))
  end

  private

  def immutable_location
    if persisted? && LOCATION_FIELDS.any? { |field| will_save_change_to_attribute?(field) } && stored_objects.exists?
      errors.add(:base, 'Storage location is referenced by objects; create a new profile')
    end
  end

  def valid_endpoints
    %i[endpoint download_endpoint public_download_origin].each do |field|
      next if public_send(field).blank?
      uri = URI.parse(public_send(field))
      allowed_schemes = ENV['ZEALOT_ALLOW_HTTP_STORAGE'] == 'true' ? %w[http https] : ['https']
      unless allowed_schemes.include?(uri.scheme) && uri.host.present? && uri.userinfo.nil? && uri.query.nil? && uri.fragment.nil? && ['', '/'].include?(uri.path)
        errors.add(field, 'must be an HTTPS origin without credentials, query or path')
      end
    rescue URI::InvalidURIError
      errors.add(field, 'is invalid')
    end
  end

  def valid_prefix
    errors.add(:prefix, 'contains unsafe path segments') if prefix.to_s.split('/', -1).any? { |part| %w[. ..].include?(part) } || prefix.to_s.start_with?('/') || prefix.to_s.end_with?('/')
  end
end
