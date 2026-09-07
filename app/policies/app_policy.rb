# frozen_string_literal: true

class AppPolicy < AppResourcePolicy
  def create?
    user&.admin? || (user && record.group_id && GroupMembership.where(user: user, group_id: record.group_id, role: 'admin').exists?)
  end
  alias new? create?

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
