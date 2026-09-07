# frozen_string_literal: true

class WebHookPolicy < ApplicationPolicy
  def index?
    admin?
  end

  def create?
    admin? || Access::AppAccess.allowed?(user, Channel.find_by(id: record.channel_id)&.app, action: :manage)
  end

  def show?
    admin? || (record.persisted? && scope.exists?(id: record.id))
  end
  alias update? show?
  alias edit? show?
  alias destroy? show?

  def test?
    show?
  end

  def console?
    show?
  end

  def enable?
    show?
  end

  def disable?
    show?
  end

  class Scope < Scope
    def resolve
      return scope.all if user&.admin?
      channels = Channel.where(scheme_id: Scheme.where(app_id: Access::AppAccess.scope(user, action: :manage))).select(:id)
      # Editing a shared destination affects every linked channel. Require
      # management of its originating channel and every current association.
      scope.where(channel_id: channels).where.not(id: ChannelsWebHook.where.not(channel_id: channels).select(:web_hook_id))
    end
  end
end
