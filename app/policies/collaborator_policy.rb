# frozen_string_literal: true
class CollaboratorPolicy < AppResourcePolicy
  def show?
    permitted?(:manage)
  end
end
