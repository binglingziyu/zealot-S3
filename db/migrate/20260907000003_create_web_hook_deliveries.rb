# frozen_string_literal: true

class CreateWebHookDeliveries < ActiveRecord::Migration[8.1]
  def change
    create_table :web_hook_deliveries, id: :uuid do |t|
      t.references :web_hook, foreign_key: { on_delete: :nullify }
      t.references :channel, foreign_key: { on_delete: :nullify }
      t.references :release, foreign_key: { on_delete: :nullify }
      t.references :user, foreign_key: { on_delete: :nullify }
      t.string :event_name, null: false
      t.string :deduplication_key, null: false
      t.string :state, null: false, default: 'pending'
      t.boolean :test_event, null: false, default: false
      t.integer :attempts, null: false, default: 0
      t.datetime :attempted_at
      t.integer :response_status
      t.string :error_class
      t.timestamps
    end
    add_index :web_hook_deliveries, :deduplication_key, unique: true
    add_index :web_hook_deliveries, [:state, :updated_at]
  end
end
