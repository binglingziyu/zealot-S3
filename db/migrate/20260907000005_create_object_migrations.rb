class CreateObjectMigrations < ActiveRecord::Migration[8.1]
  def change
    create_table :object_migrations, id: :uuid do |t|
      t.references :source_object, null: false, foreign_key: { to_table: :stored_objects }
      t.references :target_object, null: false, foreign_key: { to_table: :stored_objects }
      t.references :user, foreign_key: { on_delete: :nullify }
      t.string :state, null: false, default: 'pending'
      t.integer :attempts, null: false, default: 0
      t.string :error_class
      t.timestamps
    end
    add_index :object_migrations, [:source_object_id, :target_object_id], unique: true
  end
end
