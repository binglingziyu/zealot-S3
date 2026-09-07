# frozen_string_literal: true

class ReconcileWebHookDeliveriesJob < ApplicationJob
  queue_as :schedule

  def perform
    return if ENV['ZEALOT_RECOVERY_MODE'] == 'true'
    WebHookDelivery.where(state: 'sending').where('attempted_at < ?', 10.minutes.ago)
      .update_all(state: 'uncertain', error_class: 'WorkerInterrupted', updated_at: Time.current)
    WebHookDelivery.where(state: 'pending').where('updated_at < ?', 1.minute.ago).find_each do |delivery|
      delivery.schedule_delivery
    end
  end
end
