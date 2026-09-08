# frozen_string_literal: true
class ReleasePolicy < AppResourcePolicy
  def show?
    record.channel.share_enabled? || super
  end

  def create?
    permitted?(:upload)
  end
  alias new? create?
  alias auth? show?
end
