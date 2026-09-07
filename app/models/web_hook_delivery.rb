# frozen_string_literal: true

class WebHookDelivery < ApplicationRecord
  EVENTS = %w[upload_events download_events changelog_events].freeze
  belongs_to :web_hook, optional: true
  belongs_to :channel, optional: true
  belongs_to :release, optional: true
  belongs_to :user, optional: true
  enum :state, %w[pending sending sent uncertain failed skipped].index_with(&:itself), prefix: true, validate: true
  validates :event_name, inclusion: { in: EVENTS }
  validates :deduplication_key, presence: true, length: { maximum: 200 }
  after_create_commit :schedule_delivery

  def self.enqueue(event:, web_hook:, release:, user:, key:, test_event: false)
    return if ENV['ZEALOT_RECOVERY_MODE'] == 'true' || !EVENTS.include?(event) || !release
    return unless web_hook.channels.exists?(release.channel_id) && Access::AppAccess.allowed?(user, release.app, action: :view)
    create_or_find_by!(deduplication_key: key) do |delivery|
      delivery.assign_attributes(event_name: event, web_hook: web_hook, release: release,
        channel: release.channel, user: user, test_event: test_event)
    end
  end

  def eligible?
    web_hook && channel && release && user && release.channel_id == channel_id &&
      web_hook.channels.exists?(channel_id) && (test_event || web_hook.public_send(event_name) == 1) &&
      Access::AppAccess.allowed?(user, release.app, action: :view)
  end

  # Restore tools call this while workers are stopped and recovery mode is on.
  # The old DB cannot prove which pre-restore requests reached their recipients.
  def self.suppress_before!(cutoff)
    raise ArgumentError, 'Recovery mode is required' unless ENV['ZEALOT_RECOVERY_MODE'] == 'true'
    where('created_at <= ?', cutoff).where(state: %w[pending sending uncertain failed])
      .update_all(state: 'skipped', error_class: 'RecoverySuppressed', updated_at: Time.current)
  end

  def retry_delivery!(actor)
    raise ArgumentError, 'Notifications are disabled during recovery' if ENV['ZEALOT_RECOVERY_MODE'] == 'true'
    with_lock do
      raise ArgumentError, 'Only failed or uncertain notifications can be retried' unless state_failed? || state_uncertain?
      raise Pundit::NotAuthorizedError unless web_hook && WebHookPolicy.new(actor, web_hook).update? &&
        channel && Access::AppAccess.allowed?(actor, channel.app, action: :manage)
      update!(state: 'pending', response_status: nil, error_class: nil)
      AuditEvent.record!(user: actor, action: 'webhook.delivery.retry', subject: self)
    end
    schedule_delivery
  end

  def schedule_delivery
    WebHookDeliveryJob.perform_later(id)
  rescue StandardError => error
    # The committed pending row is the durable source; reconciliation requeues it.
    Rails.logger.warn("Webhook delivery #{id} could not be queued: #{error.class.name}")
  end
end
