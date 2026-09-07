# frozen_string_literal: true

class GroupMembership < ApplicationRecord
  belongs_to :group
  belongs_to :user
  enum :role, { viewer: 'viewer', developer: 'developer', admin: 'admin' }, validate: true
  validates :user_id, uniqueness: { scope: :group_id }
  after_save :invalidate_access
  after_destroy :invalidate_access

  private

  def invalidate_access
    Group.where(id: [group_id, group_id_before_last_save].compact).update_all('access_version = access_version + 1')
  end
end
