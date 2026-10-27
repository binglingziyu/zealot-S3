# frozen_string_literal: true
module Storage
  class ProfileWriter
    ATTRIBUTES = %i[name provider region bucket endpoint download_endpoint public_download_origin prefix force_path_style enabled system_default url_expires_in].freeze

    def self.save!(profile, user:, payload:)
      raise Pundit::NotAuthorizedError unless user&.admin?
      secrets = %w[access_key_id secret_access_key session_token].to_h { |key| [key, payload[key]] }
      StorageProfile.transaction do
        # Serialize all profile writes, including clearing a default, so a
        # concurrent switch cannot race grant replacement or credential updates.
        StorageProfile.connection.execute('SELECT pg_advisory_xact_lock(2026090701)')
        profile.reload if profile.persisted?
        profile.assign_attributes(ATTRIBUTES.each_with_object({}) { |key, values| values[key] = payload[key.to_s] if payload.key?(key.to_s) })
        profile.credentials = secrets if secrets.values.any?(&:present?)
        StorageProfile.where(system_default: true).where.not(id: profile.id).update_all(system_default: false) if profile.system_default?
        profile.save!
        { 'group_ids' => [Group, :group_id], 'app_ids' => [App, :app_id] }.each do |key, (model, foreign_key)|
          next unless payload.key?(key)
          values = payload[key]
          raise ArgumentError, "#{key} must be an array" unless values.is_a?(Array)
          ids = values.reject(&:blank?).map { |id| Integer(id.to_s, 10) }.uniq
          raise ArgumentError, "Invalid #{key}" unless ids.all? { |id| id.between?(1, 2**63 - 1) }
          records = model.where(id: ids)
          raise ArgumentError, "Unknown #{model.name}" unless records.count == ids.size
          profile.storage_grants.where.not(foreign_key => nil).where.not(foreign_key => ids).destroy_all
          records.each { |record| profile.storage_grants.find_or_create_by!(foreign_key => record.id) }
        end
        AuditEvent.record!(user: user, action: 'storage.save', subject: profile)
      end
      profile
    end
  end
end
