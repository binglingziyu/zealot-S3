# frozen_string_literal: true
class ChannelPolicy < AppResourcePolicy
  def upload?
    permitted?(:upload)
  end

  alias versions? show?
  alias branches? show?
  alias release_types? show?
  alias destroy_releases? destroy?
end
