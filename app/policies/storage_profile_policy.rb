# frozen_string_literal: true
class StorageProfilePolicy < ApplicationPolicy
  def index?
    user&.admin?
  end
  alias show? index?
  alias create? index?
  alias new? index?
  alias edit? index?
  alias update? index?
  alias destroy? index?
  alias check? index?

  class Scope < ApplicationPolicy::Scope
    def resolve
      user&.admin? ? scope.all : scope.none
    end
  end
end
