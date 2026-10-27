# frozen_string_literal: true

class Download::DebugFilesController < ApplicationController
  before_action :set_debug_file

  rescue_from ActiveRecord::RecordNotFound, with: :render_not_found_entity_response

  def show
    return render_not_found_entity_response unless @debug_file.file.stored_file_exists?

    redirect_to filename_download_debug_file_url(@debug_file, @debug_file.download_filename)
  end

  def download
    return render_not_found_entity_response unless @debug_file.file.stored_file_exists?

    if @debug_file.file.remote_storage?
      response.headers['Cache-Control'] = 'private, no-store'
      return redirect_to @debug_file.file.signed_download_url(filename: @debug_file.download_filename), allow_other_host: true
    end

    headers['Content-Length'] = @debug_file.file.size
    send_file @debug_file.file.path,
              filename: @debug_file.download_filename,
              disposition: 'attachment'
  end

  private

  def render_not_found_entity_response
    render json: {
      error: t('.not_found')
    }, status: :not_found
  end

  def set_debug_file
    authorize @debug_file = DebugFile.find(params[:id])
  end
end
