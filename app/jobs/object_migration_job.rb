# frozen_string_literal: true

class ObjectMigrationJob < ApplicationJob
  queue_as :storage_migration

  def perform(id)
    Storage::ObjectMover.run(id)
  end
end
