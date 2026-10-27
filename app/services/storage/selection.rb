# frozen_string_literal: true
module Storage
  class Selection
    def self.for_group(user, group)
      return StorageProfile.where(enabled: true) if user&.admin?
      ids = StorageGrant.where(group_id: group&.id).where.not(group_id: nil).select(:storage_profile_id)
      StorageProfile.where(enabled: true).where(system_default: true).or(StorageProfile.where(enabled: true, id: ids))
    end

    def self.for_app(user, app)
      return StorageProfile.where(enabled: true) if user&.admin?
      grants = StorageGrant.where(app_id: app.id).where.not(app_id: nil)
      grants = grants.or(StorageGrant.where(group_id: app.group_id)) if app.group_id
      StorageProfile.where(enabled: true).where(system_default: true).or(StorageProfile.where(enabled: true, id: grants.select(:storage_profile_id)))
    end
  end
end
