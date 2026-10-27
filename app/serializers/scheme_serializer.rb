# frozen_string_literal: true

class SchemeSerializer < ApplicationSerializer
  attributes :id, :name, :new_build_callout, :retained_builds, :install_code, :install_alias,
             :android_channel_id, :ios_channel_id, :install_path

  def install_path
    Rails.application.routes.url_helpers.public_install_path(object.preferred_install_path)
  end

  has_one :app
  has_many :channels
end
