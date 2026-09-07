# frozen_string_literal: true

class Releases::InstallController < ApplicationController

  rescue_from ActiveRecord::RecordNotFound, with: :render_not_found_entity_response

  def show
    @release = Release.version_by_channel(params[:channel_id], params[:release_id])
    if @release.file.remote_storage?
      # iOS fetches the manifest outside the browser cookie session. A short
      # lived, release-specific ticket authorizes this handoff to the installer.
      ticket_release = Release.find_signed(params[:ticket], purpose: @release.s3_install_purpose) if params[:ticket].present?
      unless helpers.logged_in_or_without_auth?(@release) || ticket_release&.id == @release.id
        return head :forbidden
      end
      return render_not_found_entity_response unless @release.file.stored_file_exists?

      response.headers['Cache-Control'] = 'private, no-store'
      @package_url = @release.file.signed_download_url(filename: @release.download_filename)
    else
      @package_url = @release.download_url
    end
    render content_type: 'text/xml', layout: false
  end

  private

  def render_not_found_entity_response
    render xml: { error: t('.not_found') }, status: :not_found
  end
end

