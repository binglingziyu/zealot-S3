# frozen_string_literal: true

class AddInstallAccessToSchemes < ActiveRecord::Migration[8.1]
  def change
    add_column :schemes, :install_access, :string, null: false, default: 'inherit'
    add_column :schemes, :install_password_digest, :string
  end
end
