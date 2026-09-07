# frozen_string_literal: true

class WebHooksController < ApplicationController
  include AppArchived

  before_action :authenticate_user!
  before_action :set_channel
  before_action :set_web_hook, except: [:create]

  def create
    # Legacy custom bodies are executable Ruby (JB), so only platform admins
    # may supply one. Application admins use the standard event payload.
    raise Pundit::NotAuthorizedError if !current_user.admin? && params.dig(:web_hook, :body).present?
    @web_hook = WebHook.new(web_hook_params)
    @web_hook.channel_id = @channel.id
    authorize @web_hook
    unless @web_hook.save
      return redirect_to_channel_url status: :see_other, alert: @web_hook.errors.full_messages.join(', ')
    end

    @channel.web_hooks << @web_hook
    audit('create')
    redirect_to_channel_url notice: t('activerecord.success.create', key: t('web_hooks.title'))
  end

  def destroy
    authorize @web_hook
    @web_hook.destroy
    audit('destroy')
    redirect_to_channel_url notice: t('activerecord.success.destroy', key: t('web_hooks.title')), status: :see_other
  end

  def disable
    authorize @web_hook
    @channel.web_hooks.delete @web_hook
    audit('disable')
    redirect_to_channel_url notice: t('admin.web_hooks.messages.success.disable')
  end

  def enable
    authorize @web_hook
    @web_hook.with_lock do
      @web_hook.channels << @channel unless @web_hook.channels.exists?(@channel.id)
    end
    audit('enable')
    redirect_to channel_url(@channel, anchor: 'enabled'), notice: t('admin.web_hooks.messages.success.enable')
  end

  def test
    authorize @web_hook
    event = params[:event] || 'upload_events'
    return head :unprocessable_entity unless %w[upload_events download_events changelog_events].include?(event)
    AppWebHookJob.perform_later event, @web_hook, @channel, current_user.id
    redirect_to_channel_url notice: t('admin.web_hooks.messages.success.test')
  end

  private

  def audit(action)
    AuditEvent.record!(user: current_user, action: "webhook.#{action}", subject: @web_hook, details: { channel_id: @channel.id })
  end

  def set_channel
    @channel = Channel.friendly.find(params[:channel_id])
    authorize @channel, :update?
    raise_if_app_archived!(@channel.app)
  end

  def set_web_hook
    @web_hook = policy_scope(WebHook).find(params[:id])
    raise ActiveRecord::RecordNotFound unless action_name == 'enable' || @channel.web_hooks.exists?(@web_hook.id)
  end

  def web_hook_params
    params.require(:web_hook).permit(
      :url, :body,
      :upload_events, :changelog_events, :download_events
    )
  end

  def redirect_to_channel_url(**options)
    redirect_to friendly_channel_overview_path(@channel), **options
  end
end
