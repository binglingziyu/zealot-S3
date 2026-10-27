# frozen_string_literal: true

module PublicLinkable
  extend ActiveSupport::Concern

  included do
    has_many :public_links, as: :target, dependent: :destroy
    before_validation :normalize_install_alias
    validate :validate_public_paths
    after_save :register_public_paths
  end

  def preferred_install_path
    install_alias.presence || default_install_path
  end

  private

  def normalize_install_alias
    self.install_alias = install_alias.to_s.strip.presence
  end

  def validate_public_paths
    public_path_attributes.each do |attribute|
      path = public_send(attribute)
      next if path.blank? || (!new_record? && !will_save_change_to_attribute?(attribute))

      errors.add(attribute, I18n.t('install_links.errors.unavailable')) unless PublicLink.available?(path, target: self)
    end
  end

  def register_public_paths
    public_path_attributes.each do |attribute|
      path = public_send(attribute)
      PublicLink.claim!(path, self) if path.present?
    end
  end
end
