# frozen_string_literal: true

class MakeInstallAccessIndependent < ActiveRecord::Migration[8.1]
  def up
    execute "UPDATE schemes SET install_access = 'members' WHERE install_access = 'inherit'"
    change_column_default :schemes, :install_access, from: 'inherit', to: 'members'
  end

  def down
    execute "UPDATE schemes SET install_access = 'inherit' WHERE install_access = 'public'"
    change_column_default :schemes, :install_access, from: 'members', to: 'inherit'
  end
end
