class BindDatabaseBackupsToStorage < ActiveRecord::Migration[8.1]
  def change
    add_reference :backups, :storage_profile, foreign_key: true
  end
end
