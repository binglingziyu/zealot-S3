# frozen_string_literal: true

module Access
  class UnifiedInstall
    def self.fingerprint(scheme)
      Digest::SHA256.hexdigest([scheme.install_access, scheme.install_password_digest,
        scheme.android_channel_id, scheme.ios_channel_id, AppAccess.version(App.find(scheme.app_id))].join(':'))
    end

    def self.ticket(scheme, release, user)
      verifier.generate({ scheme: scheme.id, release: release.id, fingerprint: fingerprint(scheme),
        member: scheme.install_access == 'members' ? user&.id : nil },
        expires_in: 10.minutes, purpose: 'ios-install')
    end

    def self.valid_ticket?(ticket, scheme, release)
      return false unless release.ios?
      data = verifier.verified(ticket, purpose: 'ios-install')&.with_indifferent_access if ticket.present?
      return false unless data && data[:scheme] == scheme.id && data[:release] == release.id &&
        data[:fingerprint] == fingerprint(scheme)
      return true unless scheme.install_access == 'members'

      AppAccess.allowed?(User.find_by(id: data[:member]), scheme.app)
    end

    def self.verifier
      Rails.application.message_verifier('unified-install')
    end
    private_class_method :verifier
  end
end
