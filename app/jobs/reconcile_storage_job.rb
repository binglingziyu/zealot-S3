# frozen_string_literal: true
class ReconcileStorageJob < ApplicationJob
  queue_as :schedule

  def perform
    return if ENV['ZEALOT_RECOVERY_MODE'] == 'true'
    StorageProfile.find_each do |profile|
      Storage::Reconciler.new(profile).call
    rescue Aws::Errors::ServiceError, Seahorse::Client::NetworkingError => error
      Rails.logger.warn("Storage reconciliation profile #{profile.id}: #{error.class.name}")
    end
  end
end
