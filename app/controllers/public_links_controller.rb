# frozen_string_literal: true

class PublicLinksController < ApplicationController
  include Qrcode
  before_action :set_link
  rate_limit to: 10, within: 5.minutes, only: :auth,
    by: -> { "#{request.remote_ip}:#{@target&.id || params[:public_slug]}" },
    with: -> { head :too_many_requests }
  before_action :set_channels, except: :auth
  before_action :check_install_access, except: :auth

  def show
    if @target.is_a?(Channel)
      return redirect_to friendly_channel_releases_path(@target), status: :found
    end

    platform = detected_platform
    if platform && params[:choose] != '1'
      channel = @channels.find { |entry| entry.device_type == platform }
      return redirect_to public_install_channel_path(@link.path, channel.id), status: :found if channel
    end

    @requested_platform = platform
    @title = @target.app_name
    @entries = @channels.map do |channel|
      { channel: channel, release: channel.latest_release }
    end
  end

  def release
    @channel = @channels.find { |channel| channel.id.to_s == params[:channel_id] } || raise(ActiveRecord::RecordNotFound)
    @release = @channel.latest_release
    if @release
      @release.public_install_link = @link
      @release.public_install_user = current_user
    end
    @title = @target.app_name
  end

  def download
    return head :not_found unless @release.file.stored_file_exists?

    @release.channel.perform_web_hook('download_events', current_user&.id, release: @release)
    if @release.file.remote_storage?
      return redirect_to @release.file.signed_download_url(filename: @release.download_filename), allow_other_host: true
    end

    response.headers['Content-Length'] = @release.file.size
    send_file @release.file.path, filename: @release.download_filename, disposition: 'attachment'
  end

  def install
    return head :not_found unless @release.platform == 'iOS' && @release.file.stored_file_exists?

    @package_url = if @release.file.remote_storage?
      @release.file.signed_download_url(filename: @release.download_filename)
    else
      ticket = params[:ticket].presence || Access::UnifiedInstall.ticket(@target, @release, current_user)
      public_install_download_url(@link.path, @release.id, ticket: ticket)
    end
    render 'releases/install/show', content_type: 'text/xml', layout: false
  end

  def qrcode
    render qrcode: public_install_url(@link.path), **qrcode_options
  end

  def auth
    raise ActiveRecord::RecordNotFound unless @target.is_a?(Scheme) && @target.install_access == 'password'

    if @target.authenticate_install_password(params[:password].to_s)
      session[install_session_key] = install_access_token
      redirect_to public_install_path(@link.path), status: :see_other
    else
      @error_message = t('install_links.invalid_password')
      render_password status: :unprocessable_entity
    end
  end

  private

  def set_link
    response.headers['Cache-Control'] = 'private, no-store'
    response.headers['Vary'] = 'User-Agent, Cookie'
    response.headers['Referrer-Policy'] = 'no-referrer'
    @link = PublicLink.lookup(params[:public_slug]) || raise(ActiveRecord::RecordNotFound)
    @target = @link.target || raise(ActiveRecord::RecordNotFound)
    @app = @target.app
    raise ActiveRecord::RecordNotFound if @app.archived?
    if %w[release download install auth].include?(action_name) && !@target.is_a?(Scheme)
      raise ActiveRecord::RecordNotFound
    end

    @member = Access::AppAccess.allowed?(current_user, @app, action: :view)
  end

  def set_channels
    candidates = @target.is_a?(Scheme) ? %w[android ios].filter_map { |p| @target.install_channel(p) } : [@target]
    @channels = @target.is_a?(Scheme) ? candidates : candidates.select { |channel| @member || channel.share_enabled? }
    raise Pundit::NotAuthorizedError if @target.is_a?(Channel) && @channels.empty?
    if %w[download install].include?(action_name)
      @release = Release.where(channel_id: @channels.map(&:id)).find(params[:release_id])
    end
  end

  def check_install_access
    return unless @target.is_a?(Scheme)
    if %w[install download].include?(action_name) &&
        Access::UnifiedInstall.valid_ticket?(params[:ticket], @target, @release)
      return
    end
    return if @member || @target.install_access == 'public'

    if @target.install_access == 'members'
      return head :forbidden if %w[install download qrcode].include?(action_name)
      return authenticate_user! unless current_user
      raise Pundit::NotAuthorizedError
    end

    return if session[install_session_key] == install_access_token

    return head :forbidden if %w[install download qrcode].include?(action_name)
    render_password
  end

  def install_session_key
    "install_access_#{@target.id}"
  end

  def install_access_token
    Access::UnifiedInstall.fingerprint(@target)
  end

  def render_password(status: :ok)
    @title = t('install_links.unified')
    render :password, status: status
  end

  def detected_platform
    agent = request.user_agent.to_s
    return 'android' if agent.match?(/Android/i)
    return 'ios' if agent.match?(/iPhone|iPad|iPod|Macintosh.*Mobile/i)
  end
end
