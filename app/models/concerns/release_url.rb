# frozen_string_literal: true

module ReleaseUrl
  extend ActiveSupport::Concern

  included do
    include Rails.application.routes.url_helpers
  end

  def download_url
    download_release_url(id)
  end

  def install_url
    return download_url unless platform == 'iOS'

    options = {}
    if file.remote_storage?
      options[:ticket] = signed_id(expires_in: file.file.stored_object&.storage_profile&.url_expires_in || Zealot::Storage::S3.expires_in, purpose: s3_install_purpose)
    end
    ios_url = channel_release_install_url(channel.slug, id, **options)
    "itms-services://?action=download-manifest&url=#{ERB::Util.url_encode(ios_url)}"
  end

  def s3_install_purpose
    "s3-install:#{Digest::SHA256.hexdigest(channel.share_mode.to_s + channel.share_password_digest.to_s)}:#{Access::AppAccess.version(app)}"
  end

  def release_url
    friendly_channel_release_url(channel, self)
  end

  def qrcode_url(size = :thumb)
    channel_release_qrcode_url(channel, self, size: size)
  end
end
