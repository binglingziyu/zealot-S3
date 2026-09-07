# frozen_string_literal: true

class UploadSession < ApplicationRecord
  belongs_to :user, optional: true
  belongs_to :app, optional: true
  belongs_to :channel, optional: true
  validates :user, :app, :channel, presence: true, on: :create
  belongs_to :stored_object
  belongs_to :release, optional: true
  belongs_to :debug_file, optional: true

  enum :state, %w[initiated uploading uploaded verifying parsing ready failed cancelled expired].index_with(&:itself), prefix: true, validate: true
  validates :idempotency_key, presence: true, length: { maximum: 200 }, uniqueness: { scope: :user_id }
  validates :expected_size, :part_size, numericality: { only_integer: true, greater_than: 0 }
  validates :expected_sha256, format: { with: /\A[0-9a-f]{64}\z/ }, allow_nil: true
  validates :expires_at, presence: true
  validate :consistent_ownership

  def upload_allowed?
    app.present? && channel.present? && user.present? && !app.archived? && Access::AppAccess.allowed?(user, app, action: :upload)
  end

  private

  def consistent_ownership
    errors.add(:channel, 'belongs to another application') if channel && channel.app.id != app_id
    errors.add(:stored_object, 'belongs to another application') if stored_object && stored_object.app_id != app_id
    errors.add(:release, 'belongs to another application') if release && release.app.id != app_id
    errors.add(:debug_file, 'belongs to another application') if debug_file && debug_file.app_id != app_id
  end
end
