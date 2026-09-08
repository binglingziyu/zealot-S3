require 'bcrypt'

class AddChannelSharing < ActiveRecord::Migration[8.1]
  class LegacyChannel < ActiveRecord::Base
    self.table_name = 'channels'
  end

  def up
    add_column :channels, :share_mode, :string, null: false, default: 'private'
    add_column :channels, :share_password_digest, :string

    LegacyChannel.reset_column_information
    LegacyChannel.where.not(password: [nil, '']).find_each do |channel|
      channel.update_columns(
        share_mode: 'password',
        share_password_digest: BCrypt::Password.create(channel.password),
        password: nil
      )
    end
    remove_column :channels, :password
  end

  def down
    add_column :channels, :password, :string
    remove_column :channels, :share_password_digest
    remove_column :channels, :share_mode
  end
end
