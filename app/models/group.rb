# frozen_string_literal: true

class Group < ApplicationRecord
  belongs_to :storage_profile, optional: true
  has_many :apps, dependent: :restrict_with_error
  has_many :group_memberships, dependent: :destroy
  has_many :users, through: :group_memberships
  has_many :storage_grants, dependent: :destroy

  validates :name, presence: true, uniqueness: true, length: { maximum: 150 }

  def invalidate_access!
    self.class.where(id: id).update_all('access_version = access_version + 1')
  end
end
