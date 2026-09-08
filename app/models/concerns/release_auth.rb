# frozen_string_literal: true

module ReleaseAuth
  extend ActiveSupport::Concern

  COOKIE_KEY_PREFIX = 'zealot_app_channel_auth_'

  def cookie_password_matched?(cookies)
    return true if channel.share_public?
    return false unless channel.share_password?

    ActiveSupport::SecurityUtils.secure_compare(
      cookies.encrypted[cache_key].to_s,
      share_auth_fingerprint
    )
  end

  def password_match?(cookies, password)
    if channel.share_password? && channel.authenticate_share_password(password.to_s)
      store_cookie_auth(cookies)
      return true
    end

    false
  end

  private

  def store_cookie_auth(cookies)
    cookies.encrypted[cache_key] = {
      value: share_auth_fingerprint,
      expires: 30.days.from_now,
      httponly: true,
      secure: Rails.env.production?,
      same_site: :lax
    }
  end

  def share_auth_fingerprint
    Digest::SHA256.hexdigest("#{channel.share_mode}:#{channel.share_password_digest}")
  end

  def cache_key
    @cache_key ||= "#{COOKIE_KEY_PREFIX}#{channel.id}"
  end
end
