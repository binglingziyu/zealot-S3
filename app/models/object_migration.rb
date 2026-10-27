# frozen_string_literal: true

class ObjectMigration < ApplicationRecord
  belongs_to :source_object, class_name: 'StoredObject'
  belongs_to :target_object, class_name: 'StoredObject'
  belongs_to :user, optional: true
  enum :state, %w[pending copying complete failed cancelled].index_with(&:itself), prefix: true, validate: true
  after_create_commit :schedule_job

  def schedule_job
    ObjectMigrationJob.perform_later(id)
  rescue StandardError => error
    Rails.logger.warn("Object migration #{id} could not be queued: #{error.class.name}")
  end
end
