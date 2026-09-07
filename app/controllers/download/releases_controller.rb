# frozen_string_literal: true

class Download::ReleasesController < ApplicationController
  before_action :set_release
  before_action :check_download_access

  rescue_from ActiveRecord::RecordNotFound, with: :render_not_found_entity_response

  def show
    return render_not_found_entity_response unless @release.file.stored_file_exists?

    redirect_to filename_download_release_url(@release, @release.download_filename)
  end

  def download
    # 触发 web_hook
    @release.channel.perform_web_hook('download_events', current_user&.id)

    return render_not_found_entity_response unless @release.file.stored_file_exists?

    if @release.file.remote_storage?
      response.headers['Cache-Control'] = 'private, no-store'
      return redirect_to @release.file.signed_download_url(filename: @release.download_filename), allow_other_host: true
    end

    headers['Content-Length'] = @release.file.size
    send_file @release.file.path,
              filename: @release.download_filename,
              disposition: 'attachment'
  end

  private

  # Check both routes so a guessed /download/.../filename cannot bypass a
  # channel password when issuing a bearer S3 download URL.
  def check_download_access
    return if helpers.logged_in_or_without_auth?(@release)

    redirect_to channel_release_path(@release.channel, @release, back_url: @release.download_url)
  end

  def render_not_found_entity_response
    render json: {
      error: t('.not_found')
    }, status: :not_found
  end


  def set_release
    @release = Release.find(params[:id])
  end
end


