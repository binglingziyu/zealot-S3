# frozen_string_literal: true

class StoredObject < ApplicationRecord
  belongs_to :storage_profile
  belongs_to :app, optional: true
  has_many :upload_sessions, dependent: :restrict_with_error
  enum :state, { pending: 'pending', uploaded: 'uploaded', ready: 'ready', deleted: 'deleted', purged: 'purged' }, prefix: true, validate: true
  validates :key, :filename, presence: true
  validates :key, uniqueness: { scope: :storage_profile_id }
  validates :kind, inclusion: { in: %w[package icon debug backup] }
  validates :byte_size, numericality: { only_integer: true, greater_than_or_equal_to: 0 }, allow_nil: true
  validates :sha256, format: { with: /\A[0-9a-f]{64}\z/ }, allow_nil: true
  validate :immutable_identity
  validate :safe_key

  def retire!
    return if state_deleted? || state_purged?
    days = [Integer(ENV.fetch('ZEALOT_OBJECT_RETENTION_DAYS', '37')), Integer(ENV.fetch('ZEALOT_DATABASE_RETENTION_DAYS', '30')) + 7].max
    update!(state: 'deleted', deleted_at: Time.current, purge_after: days.days.from_now)
  end

  def signed_url(filename: self.filename)
    raise ActiveRecord::RecordNotFound unless state_ready?

    return storage_profile.public_url(key) if kind != 'backup' && storage_profile.public_download_origin.present?

    disposition = ActionDispatch::Http::ContentDisposition.format(disposition: 'attachment', filename: filename)
    Aws::S3::Presigner.new(client: storage_profile.client(download: true)).presigned_url(
      :get_object, bucket: storage_profile.bucket, key: key,
      expires_in: storage_profile.url_expires_in, response_content_disposition: disposition
    )
  end

  def retained_reference?
    kind == 'backup' || Release.where(package_object_id: id).or(Release.where(icon_object_id: id)).exists? ||
      DebugFile.where(stored_object_id: id).exists? || ObjectMigration.where(state: %w[pending copying])
        .where('source_object_id = :id OR target_object_id = :id', id: id).exists?
  end

  def with_local_file(expected_size: byte_size)
    Storage::LocalDownload.open(client: storage_profile.client, bucket: storage_profile.bucket,
      key: key, filename: filename, expected_size: expected_size) do |path|
      yield path
    end
  end

  private

  def immutable_identity
    if persisted? && %w[storage_profile_id key app_id].any? { |field| will_save_change_to_attribute?(field) }
      errors.add(:base, 'Object ownership and location are immutable; migration requires a new object')
    end
  end

  def safe_key
    errors.add(:key, 'is unsafe') if key.to_s.start_with?('/') || key.to_s.split('/').any? { |p| p.empty? || %w[. ..].include?(p) }
  end
end
