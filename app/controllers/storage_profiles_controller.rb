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
    params.require(:storage_profile).permit(*Storage::ProfileWriter::ATTRIBUTES)
  end

  def save_profile(view)
    Storage::ProfileWriter.save!(@profile, user: current_user, payload: params.require(:storage_profile))
    redirect_to storage_profiles_path, notice: '存储配置已保存'
  rescue ActiveRecord::RecordInvalid, ArgumentError => error
    @profile.errors.add(:base, error.message) if @profile.errors.empty?
    @title = '保存对象存储'
    render view, status: :unprocessable_entity
  end
end
