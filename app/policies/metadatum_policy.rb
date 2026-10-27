# frozen_string_literal: true
class MetadatumPolicy < ApplicationPolicy
  def show?
    return false unless user
    return Access::AppAccess.allowed?(user, record.app) if record.app

    user.admin? || record.user_id == user.id
  end

  def new?
    user.present?
  end
  alias create? new?

  def destroy?
    return false unless user
    return Access::AppAccess.allowed?(user, record.app, action: :manage) if record.app

    user.admin? || record.user_id == user.id
  end

  class Scope < ApplicationPolicy::Scope
    def resolve
      Access::RecordScope.resolve(user, scope)
    end
  end
end
