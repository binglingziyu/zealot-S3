# frozen_string_literal: true

class AppResourcePolicy < ApplicationPolicy
  def index?
    user.present?
  end

  def show?
    permitted?(:view)
  end

  def create?
    permitted?(:manage)
  end
  alias new? create?
  alias update? create?
  alias edit? create?
  alias destroy? create?

  class Scope < ApplicationPolicy::Scope
    def resolve
      Access::RecordScope.resolve(user, scope)
    end
  end

  protected

  def app
    record.is_a?(App) ? record : record.try(:app)
  end

  def permitted?(action)
    Access::AppAccess.allowed?(user, app, action: action)
  end
end
