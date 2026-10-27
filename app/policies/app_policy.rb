# frozen_string_literal: true

class AppPolicy < AppResourcePolicy
  def create?
    user&.admin? || (user && record.group_id && GroupMembership.where(user: user, group_id: record.group_id, role: 'admin').exists?)
  end
  def new?
    user&.admin? || creatable_groups.exists?
  end

  def creatable_groups
    return Group.none unless user
    return Group.all if user.admin?

    Group.where(id: GroupMembership.where(user: user, role: 'admin').select(:group_id))
  end

  def update?
    permitted?(:manage)
  end
  alias edit? update?
  alias destroy? update?
  alias archive? update?
  alias archived? index?
  alias unarchive? update?
  alias new_owner? update?
  alias update_owner? update?
end
