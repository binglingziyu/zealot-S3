# frozen_string_literal: true

class Scheme < ApplicationRecord
  default_scope { order(id: :asc) }
  include PublicLinkable

  belongs_to :app
  has_many :channels, dependent: :destroy
  accepts_nested_attributes_for :channels
  belongs_to :android_channel, class_name: 'Channel', optional: true
  belongs_to :ios_channel, class_name: 'Channel', optional: true

  before_validation :set_install_code, on: :create
  validate :validate_install_channels
  validate :immutable_install_code, on: :update

  validates :name, presence: true
  INSTALL_ACCESS_MODES = %w[public password members].freeze
  has_secure_password :install_password, validations: false
  validates :install_access, inclusion: { in: INSTALL_ACCESS_MODES }
  validates :install_password, length: { minimum: 4, maximum: 72 }, allow_nil: true
  validate :install_password_required

  after_destroy :delete_app_recently_releases_cache

  def app_name
    "#{app.name} #{name}"
  end

  def latest_channel
    channels.take
  end

  def total_releases
    channels.size
  end

  def default_install_path
    install_code
  end

  def install_channel(platform)
    selected = public_send("#{platform}_channel")
    return selected if selected && selected.scheme_id == id && selected.device_type == platform.to_s

    candidates = channels.where(device_type: platform).limit(2).to_a
    candidates.one? ? candidates.first : nil
  end

  def serializable_hash(options = nil)
    super((options || {}).merge(except: Array(options&.dig(:except)) + %w[install_password_digest]))
  end

  private

  def install_password_required
    if install_access == 'password' && install_password_digest.blank?
      errors.add(:install_password, :blank)
    end
    if install_password && install_password.bytesize > 72
      errors.add(:install_password, I18n.t('install_links.errors.password_length'))
    end
  end

  def public_path_attributes
    %i[install_code install_alias]
  end

  def set_install_code
    self.install_code ||= PublicLink.generate_code
  end

  def immutable_install_code
    errors.add(:install_code, I18n.t('install_links.errors.immutable')) if will_save_change_to_install_code?
  end

  def validate_install_channels
    %w[android ios].each do |platform|
      channel = public_send("#{platform}_channel")
      next if public_send("#{platform}_channel_id").blank?
      unless channel && channel.scheme_id == id && channel.device_type == platform
        errors.add("#{platform}_channel", I18n.t('install_links.errors.channel'))
      end
    end
  end

  def recently_release_cache_key
    @recently_release_cache_key ||= "app_#{app.id}_recently_release"
  end

  def delete_app_recently_releases_cache
    Rails.cache.delete(recently_release_cache_key)
  end
end
