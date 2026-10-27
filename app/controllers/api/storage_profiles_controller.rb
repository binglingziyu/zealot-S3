# frozen_string_literal: true
class Api::StorageProfilesController < Api::BaseController
  before_action :validate_user_token
  before_action { authorize StorageProfile, :index? }
  before_action :set_profile, except: %i[index create]
  rescue_from ArgumentError, with: :invalid_profile

  def index
    render json: policy_scope(StorageProfile).order(:id).map { |profile| representation(profile) }
  end

  def show
    render json: representation(@profile)
  end

  def create
    @profile = StorageProfile.new
    persist(:created)
  end

  def update
    persist(:ok)
  end

  def destroy
    unless @profile.destroy
      return render json: { error: @profile.errors.full_messages.to_sentence }, status: :unprocessable_entity
    end
    AuditEvent.record!(user: current_user, action: 'storage.destroy', subject: @profile)
    head :no_content
  end

  def check
    @profile.client.head_bucket(bucket: @profile.bucket)
    render json: { accessible: true }
  rescue Aws::Errors::ServiceError, Seahorse::Client::NetworkingError => error
    render json: { accessible: false, error: error.class.name.demodulize }, status: :unprocessable_entity
  end

  private

  def set_profile
    @profile = policy_scope(StorageProfile).find(params[:id])
  end

  def persist(status)
    Storage::ProfileWriter.save!(@profile, user: current_user, payload: params.require(:storage_profile))
    render json: representation(@profile), status: status
  end

  def representation(profile)
    profile.attributes.slice('id', *Storage::ProfileWriter::ATTRIBUTES.map(&:to_s)).merge(
      'credentials_version' => profile.credentials_version,
      'group_ids' => profile.storage_grants.where.not(group_id: nil).pluck(:group_id),
      'app_ids' => profile.storage_grants.where.not(app_id: nil).pluck(:app_id))
  end

  def invalid_profile(error)
    render json: { error: error.message }, status: :unprocessable_entity
  end
end
