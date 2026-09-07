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
      # Jobs may hold a User instance across a long download/parse. Re-read the
      # identity so locking/deleting an account also revokes publication.
      user = User.find_by(id: user.id) if user
      return App.none unless user&.api_access_active?
      return App.none if user.service_account? && action == :manage
      return App.all if user.admin?

      direct = Collaborator.where(user_id: user.id, role: roles.fetch(:app)).select(:app_id)
      return App.where(id: direct) if user.service_account?
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
