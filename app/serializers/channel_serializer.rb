# frozen_string_literal: true

class ChannelSerializer < ApplicationSerializer
  attributes :id, :slug, :name, :device_type, :bundle_id, :git_url, :has_password,
             :share_mode, :key, :download_filename_type, :install_alias, :install_path

  def install_path
    Rails.application.routes.url_helpers.public_install_path(object.preferred_install_path)
  end

  def has_password
    object.share_password_digest.present?
  end
end
