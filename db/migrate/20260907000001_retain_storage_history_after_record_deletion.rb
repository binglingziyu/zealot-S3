# frozen_string_literal: true
class RetainStorageHistoryAfterRecordDeletion < ActiveRecord::Migration[8.1]
  def change
    remove_foreign_key :stored_objects, :apps
    add_foreign_key :stored_objects, :apps, on_delete: :nullify
    %i[user app channel release debug_file].each do |name|
      table = name.to_s.pluralize.to_sym
      remove_foreign_key :upload_sessions, table
      add_foreign_key :upload_sessions, table, on_delete: :nullify
    end
    %i[user app channel].each { |name| change_column_null :upload_sessions, "#{name}_id", true }
  end
end
