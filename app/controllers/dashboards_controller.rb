# frozen_string_literal: true

class DashboardsController < ApplicationController
  before_action :authenticate_user! unless Setting.guest_mode

  def index
    @title = t('dashboard.title')

    system_analytics
    recently_upload

    # flash.now[:warn] = {
    #   title: 'warn title',
    #   message: 'warn warn warn warn warn warn warn warn warn warn',
    #     delay: 2000
    # }
    # flash.now[:notice] = 'Test successful notification message.'
    # flash.now[:warn] = 'Test warning notification message.'
    # flash.now[:alert] = 'Test failure notification message.'
  end

  private

  def recently_upload
    @releases = policy_scope(Release).page(params.fetch(:page, 1))
                       .per(params.fetch(:per_page, Setting.per_page)).order(id: :desc)
  end

  def system_analytics
    general_widgets
    admin_panels
  end

  def general_widgets
    @analytics = {
      apps: user_apps,
      debug_files: user_debug_files,
      teardowns: user_teardowns,
      releases: app_uploads,
    }
  end

  def admin_panels
    return unless current_user&.admin?

    @analytics.merge!({
      users: User.count,
      webhooks: WebHook.count,
      jobs: job_stats,
      disk: disk_usage,
    })
  end

  def job_stats
    filters = GoodJob::JobsFilter.new(params)
    states = filters.states
    "#{states["running"]} / #{states.values.sum}"
  end

  def disk_usage
    disk = Sys::Filesystem.stat(Rails.root)
    percent = (disk.bytes_used.to_f / disk.bytes_total.to_f * 100.0)
    ActiveSupport::NumberHelper.number_to_percentage(percent, precision: 0)
  end

  def user_apps
    policy_scope(App).count
  end

  def user_teardowns
    Access::RecordScope.resolve(current_user, Metadatum).count
  end

  def user_debug_files
    policy_scope(DebugFile).count
  end

  def app_uploads
    policy_scope(Release).count
  end
end
