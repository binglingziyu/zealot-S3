# frozen_string_literal: true

class WebHookDeliveryJob < ApplicationJob
  queue_as :webhook

  def perform(id)
    return if ENV['ZEALOT_RECOVERY_MODE'] == 'true'
    delivery = WebHookDelivery.find_by(id: id)
    return unless delivery
    delivery.with_lock do
      return unless delivery.state_pending?
      unless delivery.eligible?
        delivery.update!(state: 'skipped', error_class: 'AuthorizationOrDestinationChanged')
        return
      end
      # Commit the claim before HTTP. A lost response is never auto-resubmitted.
      delivery.update!(state: 'sending', attempted_at: Time.current, attempts: delivery.attempts + 1)
    end
    claimed_attempt = delivery.attempts
    payload = AppWebHookJob.new.render_payload(event: delivery.event_name, web_hook: delivery.web_hook,
      release: delivery.release, user: delivery.user)
    request_started = true
    response = Faraday.post(delivery.web_hook.url, payload,
      { 'Content-Type' => 'application/json', 'Idempotency-Key' => delivery.id, 'X-Zealot-Delivery-ID' => delivery.id }) do |request|
      request.options.open_timeout = 10
      request.options.timeout = 30
    end
    finish(delivery, claimed_attempt, state: response.status.between?(200, 299) ? 'sent' : 'uncertain', response_status: response.status)
  rescue StandardError => error
    if claimed_attempt
      finish(delivery, claimed_attempt, state: request_started ? 'uncertain' : 'failed', error_class: error.class.name)
    end
    Rails.logger.warn("Webhook delivery #{id}: #{error.class.name}")
  end

  private

  def finish(delivery, attempt, **attributes)
    delivery.with_lock do
      delivery.update!(attributes) if delivery.state_sending? && delivery.attempts == attempt
    end
  end
end
