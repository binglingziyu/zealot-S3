# frozen_string_literal: true

class Api::AppsController < Api::BaseController
  include AppArchived

  before_action :validate_user_token
  before_action :set_app, only: %i[show update destroy]

  # GET /api/apps
  def index
    @apps = app_scopes
    authorize @apps.first if @apps.present?

    render json: @apps, each_serializer: Api::AppSerializer, include: 'schemes.channels'
  end

  # GET /api/apps/arquived
  def archived
    @apps = policy_scope(App).archived
    authorize @apps.first if @apps.present?

    render json: @apps, each_serializer: Api::AppSerializer, include: 'schemes.channels'
  end

  # GET /api/apps/:id
  def show
    relationship = ['schemes.channels']
    relationship << 'collaborators' if manage_user?(app: @app)

    render json: @app, serializer: Api::AppSerializer, include: relationship
  end

  # POST /api/apps
  def create
    @app = App.new(app_params)
    authorize @app
    Access::AppSettings.validate!(current_user, @app)
    @app.save!
    @app.create_owner(current_user)

    render json: @app, serializer: Api::AppSerializer, include: 'schemes.channels', status: :created
  end

  # PUT /api/apps/:id
  def update
    raise_if_app_archived!(@app)

    @app.assign_attributes(app_params)
    Access::AppSettings.validate!(current_user, @app)
    @app.save!
    render json: @app, serializer: Api::AppSerializer, include: 'schemes.channels'
  end

  # DELETE /api/apps/:id
  def destroy
    @app.destroy!
    render json: { mesage: 'OK' }
  end

  protected

  def app_scopes
    case params[:scope]
    when 'archived'
      policy_scope(App).archived
    when 'active'
      policy_scope(App).active
    else
      policy_scope(App)
    end
  end

  def set_app
    @app = App.find(params[:id])
    authorize @app
  end

  def app_params
    @app_params ||= params.permit(:name, :group_id, :storage_profile_id, :inherit_group_permissions)
  end
end
