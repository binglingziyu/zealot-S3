# frozen_string_literal: true
class ReleasePolicy < AppResourcePolicy
  def create?
    permitted?(:upload)
  end
  alias new? create?
  alias auth? show?
end
