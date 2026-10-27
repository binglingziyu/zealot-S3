# frozen_string_literal: true

class Collaborator < ApplicationRecord
  self.table_name = "apps_users"
  self.primary_key = %i[user_id app_id]

  belongs_to :user
  belongs_to :app

  default_scope { order(owner: :desc, role: :desc) }

  enum :role, %i[member developer admin]

  validates :owner, inclusion: [ true, false ]
  validates :role, presence: true, exclusion: { in: Collaborator.roles.values }

  validate :one_owner_on_each_app, if: :owner_is_truth?

  after_save :invalidate_app_access
  after_destroy :invalidate_app_access

  private

  def invalidate_app_access
    App.where(id: [app_id, app_id_before_last_save].compact).update_all('access_version = access_version + 1')
  end

  def one_owner_on_each_app
    collaborator = Collaborator.find_by(app: app, owner: true)
    return true if collaborator.blank? || collaborator.user != user

    errors.add(:owner, :unique)
  end

  def owner_is_truth?
    owner == true
  end
end
