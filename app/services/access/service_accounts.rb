# frozen_string_literal: true

module Access
  class ServiceAccounts
    def self.create!(actor:, name:, role:, app_ids:)
      authorize!(actor)
      User.transaction do
        account = User.create!(username: name, email: "service-#{SecureRandom.uuid}@accounts.zealot.invalid",
          role: :member, service_account: true, password: SecureRandom.hex(48), confirmed_at: Time.current)
        grant!(actor: actor, account: account, role: role, app_ids: app_ids)
        AuditEvent.record!(user: actor, action: 'service_account.created', subject: account)
        account
      end
    end

    def self.grant!(actor:, account:, role:, app_ids:)
      authorize!(actor, account)
      raise ArgumentError, 'Role must be read or upload' unless %w[read upload].include?(role)
      ids = Array(app_ids).map { |id| Integer(id) }.uniq
      raise ArgumentError, 'Specify existing application IDs' unless ids.any? && App.where(id: ids).count == ids.size
      account.with_lock do
        account.collaborators.destroy_all
        account.group_memberships.destroy_all
        ids.each { |id| Collaborator.create!(user: account, app_id: id, role: role == 'upload' ? :developer : :member) }
        AuditEvent.record!(user: actor, action: 'service_account.grants', subject: account, details: { role: role, app_ids: ids })
      end
      account
    end

    def self.rotate!(actor:, account:)
      authorize!(actor, account)
      raise ArgumentError, 'Account is revoked' unless account.api_access_active?
      account.update!(token: SecureRandom.hex(32))
      AuditEvent.record!(user: actor, action: 'service_account.rotated', subject: account)
      account
    end

    def self.revoke!(actor:, account:)
      authorize!(actor, account)
      account.update!(locked_at: Time.current, token: SecureRandom.hex(32))
      AuditEvent.record!(user: actor, action: 'service_account.revoked', subject: account)
      account
    end

    def self.authorize!(actor, account = nil)
      raise ArgumentError, 'Account changes are disabled during recovery' if ENV['ZEALOT_RECOVERY_MODE'] == 'true'
      actor = User.find_by(id: actor.id) if actor
      raise Pundit::NotAuthorizedError unless actor&.admin? && actor.active_for_authentication?
      raise ArgumentError, 'Not a service account' if account && !account.service_account?
    end
  end
end
