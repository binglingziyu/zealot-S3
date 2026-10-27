# frozen_string_literal: true

class PublicLinksController < ApplicationController
  include Qrcode
  before_action :set_link

  def show
    if @target.is_a?(Channel)
      return redirect_to friendly_channel_releases_path(@target), status: :found
    end

    platform = detected_platform
    if platform && params[:choose] != '1'
      channel = @channels.find { |entry| entry.device_type == platform }
      return redirect_to friendly_channel_releases_path(channel), status: :found if channel
    end

    @requested_platform = platform
    @show_identity = @member || @channels.any?(&:share_public?)
    @title = @show_identity ? @target.app_name : t('install_links.title')
    @entries = @channels.map do |channel|
      { channel: channel, release: (@member || channel.share_public?) ? channel.latest_release : nil }
    end
  end

  def qrcode
    render qrcode: public_install_url(@link.path), **qrcode_options
  end

  private

  def set_link
    response.headers['Cache-Control'] = 'private, no-store'
    response.headers['Vary'] = 'User-Agent, Cookie'
    @link = PublicLink.lookup(params[:public_slug]) || raise(ActiveRecord::RecordNotFound)
    @target = @link.target || raise(ActiveRecord::RecordNotFound)
    @app = @target.app
    raise ActiveRecord::RecordNotFound if @app.archived?

    @member = Access::AppAccess.allowed?(current_user, @app, action: :view)
    candidates = @target.is_a?(Scheme) ? %w[android ios].filter_map { |p| @target.install_channel(p) } : [@target]
    @channels = candidates.select { |channel| @member || channel.share_enabled? }
    raise Pundit::NotAuthorizedError if @channels.empty?
  end

  def detected_platform
    agent = request.user_agent.to_s
    return 'android' if agent.match?(/Android/i)
    return 'ios' if agent.match?(/iPhone|iPad|iPod|Macintosh.*Mobile/i)
  end
end
