# frozen_string_literal: true
class GroupsController < ApplicationController
  before_action :authenticate_user!
  before_action :set_group, only: %i[show edit update destroy add_member remove_member]

  def index
    @title = '应用分组'
    @groups = policy_scope(Group).order(:name)
  end

  def show
    @title = @group.name
    @apps = policy_scope(App).where(group: @group).order(:name)
    @memberships = @group.group_memberships.includes(:user).order(:id) if policy(@group).members?
  end

  def new
    @group = Group.new
    authorize @group
    @title = '新建分组'
  end

  def create
    @group = Group.new(group_params)
    authorize @group
    validate_storage!
    if @group.save
      AuditEvent.record!(user: current_user, action: 'group.create', subject: @group)
      redirect_to @group, notice: '分组已创建'
    else
      @title = '新建分组'
      render :new, status: :unprocessable_entity
    end
  end

  def edit
    @title = '编辑分组'
  end

  def update
    @group.assign_attributes(group_params)
    validate_storage!
    if @group.save
      AuditEvent.record!(user: current_user, action: 'group.update', subject: @group)
      redirect_to @group, notice: '分组已保存；已有版本的存储位置保持不变'
    else
      @title = '编辑分组'
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    if @group.destroy
      AuditEvent.record!(user: current_user, action: 'group.destroy', subject: @group)
      redirect_to groups_path, notice: '分组已删除'
    else
      redirect_to @group, alert: '请先移走分组中的应用，再删除分组'
    end
  end

  def add_member
    user = User.find_by!(email: params.require(:email).strip.downcase)
    membership = @group.group_memberships.find_or_initialize_by(user: user)
    membership.role = params.require(:role)
    if membership.save
      AuditEvent.record!(user: current_user, action: 'group.member.set', subject: @group, details: { user_id: user.id, role: membership.role })
      redirect_to @group, notice: '成员权限已保存'
    else
      redirect_to @group, alert: membership.errors.full_messages.to_sentence
    end
  end

  def remove_member
    membership = @group.group_memberships.find(params[:membership_id])
    id = membership.user_id
    membership.destroy!
    AuditEvent.record!(user: current_user, action: 'group.member.remove', subject: @group, details: { user_id: id })
    redirect_to @group, notice: '分组授权已移除；应用直接授权仍单独生效'
  end

  private

  def set_group
    @group = Group.find(params[:id])
    authorize @group, %w[add_member remove_member].include?(action_name) ? :members? : "#{action_name}?"
  end

  def group_params
    params.require(:group).permit(:name, :description, :storage_profile_id)
  end

  def validate_storage!
    return if @group.storage_profile_id.blank? || !@group.will_save_change_to_storage_profile_id?
    unless Storage::Selection.for_group(current_user, @group).where(id: @group.storage_profile_id).exists?
      raise Pundit::NotAuthorizedError, 'Storage is not available to this group'
    end
  end
end
