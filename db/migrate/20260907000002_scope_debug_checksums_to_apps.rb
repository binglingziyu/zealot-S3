class ScopeDebugChecksumsToApps < ActiveRecord::Migration[8.1]
  def change
    add_index :debug_files, [:app_id, :checksum], unique: true
  end
end
