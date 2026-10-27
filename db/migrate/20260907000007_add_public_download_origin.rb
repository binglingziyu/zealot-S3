class AddPublicDownloadOrigin < ActiveRecord::Migration[8.1]
  def change
    add_column :storage_profiles, :public_download_origin, :string
  end
end
