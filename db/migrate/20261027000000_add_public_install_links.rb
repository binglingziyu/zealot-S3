# frozen_string_literal: true

class AddPublicInstallLinks < ActiveRecord::Migration[8.1]
  def up
    create_table :public_links do |t|
      t.string :path, null: false
      t.string :target_type, null: false
      t.bigint :target_id, null: false
      t.timestamps
    end
    add_index :public_links, 'lower(path)', unique: true, name: 'index_public_links_on_lower_path'
    add_index :public_links, %i[target_type target_id]
    add_column :schemes, :install_code, :string
    add_column :schemes, :install_alias, :string
    add_reference :schemes, :android_channel, foreign_key: { to_table: :channels, on_delete: :nullify }
    add_reference :schemes, :ios_channel, foreign_key: { to_table: :channels, on_delete: :nullify }
    add_column :channels, :install_alias, :string

    # Use SQL rather than application callbacks so old deployments can migrate safely.
    execute <<~SQL
      INSERT INTO public_links (path, target_type, target_id, created_at, updated_at)
      SELECT slug, 'Channel', id, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP FROM channels
      WHERE slug IS NOT NULL AND slug <> ''
    SQL
    select_values('SELECT id FROM schemes ORDER BY id').each do |id|
      begin
        code = "d#{SecureRandom.alphanumeric(7)}"
      end while select_value("SELECT 1 FROM public_links WHERE lower(path) = lower(#{quote(code)})")
      execute "UPDATE schemes SET install_code = #{quote(code)} WHERE id = #{quote(id)}"
      execute "INSERT INTO public_links (path, target_type, target_id, created_at, updated_at) VALUES (#{quote(code)}, 'Scheme', #{quote(id)}, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)"
    end
    change_column_null :schemes, :install_code, false
  end

  def down
    remove_column :channels, :install_alias
    remove_reference :schemes, :ios_channel, foreign_key: { to_table: :channels }
    remove_reference :schemes, :android_channel, foreign_key: { to_table: :channels }
    remove_column :schemes, :install_alias
    remove_column :schemes, :install_code
    drop_table :public_links
  end
end
