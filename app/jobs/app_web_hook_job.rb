# frozen_string_literal: true

class AppWebHookJob < ApplicationJob
  include Rails.application.routes.url_helpers
  include ActionView::Helpers::DateHelper
  include ActionView::Helpers::TranslationHelper
  include ActiveSupport::NumberHelper

  queue_as :webhook

  def perform(event, web_hook, channel, user_id, release_id = nil, test_event: false)
    return if ENV['ZEALOT_RECOVERY_MODE'] == 'true'
    release = release_id ? channel.releases.find_by(id: release_id) : channel.releases.last
    WebHookDelivery.enqueue(event: event, web_hook: web_hook, release: release, user: User.find_by(id: user_id),
      key: "legacy:#{job_id}:#{web_hook.id}", test_event: test_event)
  end

  def render_payload(event:, web_hook:, release:, user:)
    @event = event
    @web_hook = web_hook
    @channel = release.channel
    @release = release
    @user = user
    message_body
  end

  private

  def message_body
    build(@web_hook.body.presence || default_body)
  end

  def build(body)
    ApplicationController.render inline: body,
                                 type: :jb,
                                 assigns: {
                                   event: @event,
                                   username: @user.username,
                                   email: @user.email,
                                   title: title,
                                   name: @release.name,
                                   app_name: @release.app_name,
                                   device_type: @channel.device_type,
                                   release_version: @release.release_version,
                                   build_version: @release.build_version,
                                   bundle_id: @release.bundle_id,
                                   changelog: @release.text_changelog,
                                   file_size: @release.file_size,
                                   release_url: @release.release_url,
                                   install_url: @release.install_url,
                                   icon_url: @release.icon_url,
                                   qrcode_url: @release.qrcode_url,
                                   uploaded_at: @release.created_at,
                                   ci_url: @release.ci_url,
                                   branch: @release.branch,
                                   source: @release.source,
                                   release_type: @release.release_type
                                 }
  end

  def default_body
    '{
      event: @event,
      username: @username,
      email: @email,
      title: @title,
      name: @app_name,
      app_name: @app_name,
      device_type: @device_type,
      release_version: @release_version,
      build_version: @build_version,
      size: @file_size,
      changelog: @changelog,
      release_url: @release_url,
      install_url: @install_url,
      icon_url: @icon_url,
      qrcode_url: @qrcode_url,
      uploaded_at: @uploaded_at,
      ci_url: @ci_url,
      branch: @branch,
      source: @source,
      release_type: @release_type
    }'
  end

  def title
    case @event
    when 'upload_events'
      t('teardowns.messages.upload_events', name: @release.app_name, version: @release.release_version)
    when 'download_events'
      t('teardowns.messages.download_events', name: @release.app_name, version: @release.release_version)
    when 'changelog_events'
      t('teardowns.messages.changelog_events', name: @release.app_name, version: @release.release_version)
    else
      t('teardowns.messages.unknown_events', name: @release.app_name, event: @event)
    end
  end

  def log_message(message)
    "[Channel] #{@channel.id} #{message}"
  end

  def build_example_release
    @channel.releases.build(
      name: 'Example App',
      bundle_id: 'im.ews.zealot.example.app',
      release_version: '1.0.0',
      build_version: '5',
      git_commit: '31dbb8497b81e103ecadcab0ca724c3fd87b3ab9'
    )
  end
end
