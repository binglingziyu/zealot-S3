# frozen_string_literal: true

module Access
  # One resolver for controllers, scopes, jobs and signed URL issuance.
  class AppAccess
    ACTION_ROLES = {
      view: { app: %w[member developer admin], group: %w[viewer developer admin] },
      upload: { app: %w[developer admin], group: %w[developer admin] },
      manage: { app: %w[admin], group: %w[admin] }
    }.freeze

    def self.scope(user, action: :view)
      roles = ACTION_ROLES.fetch(action)
      return App.none unless user
      return App.all if user.admin?

      direct = Collaborator.where(user_id: user.id, role: roles.fetch(:app)).select(:app_id)
      inherited = GroupMembership.where(user_id: user.id, role: roles.fetch(:group)).select(:group_id)
      App.where(id: direct).or(App.where(inherit_group_permissions: true, group_id: inherited))
    end

    def self.allowed?(user, app, action: :view)
      return false unless app&.persisted?

      scope(user, action: action).where(id: app.id).exists?
    end

    def self.version(app)
      group_version = app.inherit_group_permissions? ? app.group&.access_version : nil
      [app.access_version, app.group_id, group_version].join(':')
    end
  end
end
