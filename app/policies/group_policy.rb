# frozen_string_literal: true
class GroupPolicy < ApplicationPolicy
  def index?
    user.present?
  end

  def show?
    Scope.new(user, Group).resolve.where(id: record.id).exists?
  end

  def create?
    user&.admin?
  end
  alias new? create?

  def update?
    user&.admin? || (user && GroupMembership.where(user: user, group: record, role: 'admin').exists?)
  end
  alias edit? update?
  alias destroy? update?
  alias members? update?

  class Scope < ApplicationPolicy::Scope
    def resolve
      return scope.none unless user
      return scope.all if user.admin?

      scope.where(id: GroupMembership.where(user: user).select(:group_id)).or(
        scope.where(id: Access::AppAccess.scope(user).where.not(group_id: nil).select(:group_id))
      )
    end
  end
end
