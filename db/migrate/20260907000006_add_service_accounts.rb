class AddServiceAccounts < ActiveRecord::Migration[8.1]
  def change
    add_column :users, :service_account, :boolean, null: false, default: false
  end
end
