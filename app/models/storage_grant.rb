# frozen_string_literal: true

class StorageGrant < ApplicationRecord
  belongs_to :storage_profile
  belongs_to :group, optional: true
  belongs_to :app, optional: true
  validate :one_subject
  validates :group_id, uniqueness: { scope: :storage_profile_id }, if: :group_id?
  validates :app_id, uniqueness: { scope: :storage_profile_id }, if: :app_id?

  private

  def one_subject
    errors.add(:base, 'Select exactly one group or application') unless group_id.present? ^ app_id.present?
  end
end
