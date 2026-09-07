# frozen_string_literal: true
module UploadSessionActions
  def create
    channel = Channel.find_by!(key: params.require(:channel_key))
    @upload = Uploads::Multipart.initiate(user: current_user, channel: channel,
      filename: params.require(:filename), byte_size: params.require(:byte_size),
      sha256: params[:sha256], idempotency_key: params.require(:idempotency_key),
      kind: params.fetch(:kind, 'package'), metadata: params.permit(:changelog, :source, :branch, :git_commit, :ci_url, :release_type, :release_version, :build_version))
    render_state(:created)
  end

  def show
    render_state
  end

  def parts
    values = request.get? ? service.uploaded_parts : service.sign_parts(params.require(:part_numbers))
    render json: { parts: values, state: @upload.state }
  end

  def complete
    service.complete
    ProcessUploadJob.perform_later(@upload.id) unless @upload.state_ready?
    render_state(:accepted)
  end

  def retry_parse
    raise ArgumentError, 'Uploads are disabled during recovery' if ENV['ZEALOT_RECOVERY_MODE'] == 'true'
    raise ArgumentError, 'Only failed analysis can be retried' unless @upload.state_failed?
    raise Pundit::NotAuthorizedError unless @upload.upload_allowed?
    @upload.update!(state: 'uploaded', error_message: nil)
    ProcessUploadJob.perform_later(@upload.id)
    render_state(:accepted)
  end

  def destroy
    service.cancel
    render_state
  end

  private

  def service
    Uploads::Multipart.new(@upload, actor: current_user)
  end

  def set_upload
    @upload = UploadSession.find(params[:id])
    unless (current_user.admin? || @upload.user_id == current_user.id) && Access::AppAccess.allowed?(current_user, @upload.app, action: :upload)
      raise Pundit::NotAuthorizedError
    end
  end

  def render_state(status = :ok)
    value = @upload.reload
    render json: { id: value.id, state: value.state, part_size: value.part_size, byte_size: value.expected_size,
      expires_at: value.expires_at, error: value.error_message,
      release_id: value.release_id, debug_file_id: value.debug_file_id,
      app_id: value.app_id,
      qrcode_url: value.state_ready? ? value.release&.qrcode_url : nil,
      result_path: value.state_ready? ? (value.release ? channel_release_path(value.channel, value.release) : debug_file_path(value.debug_file)) : nil,
      release_url: value.state_ready? ? value.release&.release_url : nil,
      install_url: value.state_ready? ? value.release&.install_url : nil }, status: status
  end

  def invalid_upload(error)
    render json: { error: error.message }, status: :unprocessable_entity
  end
end
