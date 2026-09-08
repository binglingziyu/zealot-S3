# frozen_string_literal: true

class Releases::QrcodeController < ApplicationController
  include Qrcode

  before_action :set_release

  ##
  # 显示应用的二维码
  # GET /apps/:slug/(:version)/qrcode
  def show
    raise Pundit::NotAuthorizedError unless helpers.logged_in_or_without_auth?(@release)

    render qrcode: friendly_channel_release_url(@release.channel, @release), **qrcode_options
  end

  private

  def set_release
    @release = Release.find params[:release_id]
    authorize @release, :show?
  end
end
