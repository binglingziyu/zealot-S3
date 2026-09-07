# frozen_string_literal: true
class DebugFilePolicy < AppResourcePolicy
  def create?
    app ? permitted?(:upload) : Access::AppAccess.scope(user, action: :upload).exists?
  end
  alias new? create?
  alias reprocess? create?
  alias device? show?
  alias download? show?
end
