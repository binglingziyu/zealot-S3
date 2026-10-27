# frozen_string_literal: true
class Api::GroupsController < Api::BaseController
  before_action :validate_user_token
  before_action :set_group, except: %i[index create]

  def index
    render json: policy_scope(Group).order(:id).map { |group| representation(group) }
  end

  def show
    render json: representation(@group).merge(app_ids: policy_scope(App).where(group: @group).pluck(:id))
  end

  def create
    @group = Group.new(group_params)
    authorize @group
    persist(:created, 'create')
  end

  def update
    @group.assign_attributes(group_params)
    persist(:ok, 'update')
  end

  def destroy
    unless @group.destroy
      return render json: { error: @group.errors.full_messages.to_sentence }, status: :unprocessable_entity
    end
    AuditEvent.record!(user: current_user, action: 'group.destroy', subject: @group)
    head :no_content
  end

  def members
    render json: @group.group_memberships.includes(:user).map { |member| { id: member.id, user_id: member.user_id, email: member.user.email, role: member.role } }
  end

  def add_member
    user = User.find_by!(email: params.require(:email).strip.downcase)
    member = @group.group_memberships.find_or_initialize_by(user: user)
    member.update!(role: params.require(:role))
    AuditEvent.record!(user: current_user, action: 'group.member.set', subject: @group, details: { user_id: user.id, role: member.role })
    render json: { id: member.id, user_id: member.user_id, role: member.role }
  end

  def remove_member
    member = @group.group_memberships.find(params[:membership_id])
    user_id = member.user_id
    member.destroy!
    AuditEvent.record!(user: current_user, action: 'group.member.remove', subject: @group, details: { user_id: user_id })
    head :no_content
  end

  def available_storage
    render json: Storage::Selection.for_group(current_user, @group).order(:id).map { |profile| { id: profile.id, name: profile.name, system_default: profile.system_default? } }
  end

  private

  def set_group
    @group = policy_scope(Group).find(params[:id])
    query = case action_name
            when 'members', 'add_member', 'remove_member' then :members?
            when 'available_storage' then :update?
            else "#{action_name}?"
            end
    authorize @group, query
  end

  def group_params
    params.require(:group).permit(:name, :description, :storage_profile_id)
  end

  def persist(status, action)
    if @group.storage_profile_id.present? && @group.will_save_change_to_storage_profile_id? &&
        !Storage::Selection.for_group(current_user, @group).exists?(id: @group.storage_profile_id)
      raise Pundit::NotAuthorizedError
    end
    @group.save!
    AuditEvent.record!(user: current_user, action: "group.#{action}", subject: @group)
    render json: representation(@group), status: status
  end

  def representation(group)
    group.attributes.slice('id', 'name', 'description', 'storage_profile_id', 'access_version')
  end
end
