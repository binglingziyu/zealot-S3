# frozen_string_literal: true
module Access
  class AppSettings
    def self.validate!(user, app)
      if app.will_save_change_to_group_id? && !user.admin?
        unless app.group && GroupPolicy.new(user, app.group).update?
          raise Pundit::NotAuthorizedError, 'Only a target group administrator can move applications into that group'
        end
      end
      if app.storage_profile_id && (app.will_save_change_to_storage_profile_id? || app.will_save_change_to_group_id?)
        unless Storage::Selection.for_app(user, app).where(id: app.storage_profile_id).exists?
          raise Pundit::NotAuthorizedError, 'Storage is not available to this application'
        end
      end
    end
  end
end
