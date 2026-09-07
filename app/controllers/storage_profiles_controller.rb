# frozen_string_literal: true
class StorageProfilesController < ApplicationController
  before_action :authenticate_user!
  before_action :authorize_storage_admin
  before_action :set_profile, only: %i[edit update destroy check]

  def index
    @title = '对象存储'
    @profiles = policy_scope(StorageProfile).order(:name)
  end

  def new
    @title = '添加对象存储'
    @profile = StorageProfile.new(region: 'auto', provider: 'r2', force_path_style: true)
  end

  def create
    @profile = StorageProfile.new(profile_params)
    save_profile(:new)
  end

  def edit
    @title = '编辑对象存储'
  end

  def update
    @profile.assign_attributes(profile_params)
    save_profile(:edit)
  end

  def destroy
    if @profile.destroy
      AuditEvent.record!(user: current_user, action: 'storage.destroy', subject: @profile)
      redirect_to storage_profiles_path, notice: '存储配置已删除'
    else
      redirect_to storage_profiles_path, alert: '该配置仍被应用、分组或文件引用，不能删除'
    end
  end

  def check
    @profile.client.head_bucket(bucket: @profile.bucket)
    redirect_to storage_profiles_path, notice: 'Bucket 连接成功；上传及删除权限需要通过实际上传验证'
  rescue Aws::Errors::ServiceError, Seahorse::Client::NetworkingError => error
    redirect_to storage_profiles_path, alert: "连接失败（#{error.class.name.demodulize}），请检查接口地址与凭据"
  end

  private

  def authorize_storage_admin
    authorize StorageProfile, :index?
  end

  def set_profile
    @profile = StorageProfile.find(params[:id])
  end

  def profile_params
    params.require(:storage_profile).permit(:name, :provider, :region, :bucket, :endpoint, :download_endpoint, :prefix, :force_path_style, :enabled, :system_default, :url_expires_in)
  end

  def save_profile(view)
    secrets = params.require(:storage_profile).permit(:access_key_id, :secret_access_key, :session_token).to_h
    @profile.credentials = secrets if secrets.values.any?(&:present?)
    StorageProfile.transaction do
      if @profile.system_default?
        StorageProfile.connection.execute('SELECT pg_advisory_xact_lock(2026090701)')
        StorageProfile.where(system_default: true).where.not(id: @profile.id).update_all(system_default: false)
      end
      @profile.save!
      if params[:storage_profile].key?(:group_ids)
        ids = params[:storage_profile][:group_ids].reject(&:blank?)
        groups = Group.where(id: ids)
        raise ArgumentError, 'Unknown group' unless groups.size == ids.uniq.size
        @profile.storage_grants.where.not(group_id: nil).where.not(group_id: ids).destroy_all
        groups.each { |g| @profile.storage_grants.find_or_create_by!(group: g) }
      end
      if params[:storage_profile].key?(:app_ids)
        ids = params[:storage_profile][:app_ids].reject(&:blank?)
        apps = App.where(id: ids)
        raise ArgumentError, 'Unknown application' unless apps.size == ids.uniq.size
        @profile.storage_grants.where.not(app_id: nil).where.not(app_id: ids).destroy_all
        apps.each { |a| @profile.storage_grants.find_or_create_by!(app: a) }
      end
      AuditEvent.record!(user: current_user, action: 'storage.save', subject: @profile)
    end
    redirect_to storage_profiles_path, notice: '存储配置已保存'
  rescue ActiveRecord::RecordInvalid, ArgumentError => error
    @profile.errors.add(:base, error.message) if @profile.errors.empty?
    @title = '保存对象存储'
    render view, status: :unprocessable_entity
  end
end
