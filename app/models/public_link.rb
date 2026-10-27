# frozen_string_literal: true

class PublicLink < ApplicationRecord
  belongs_to :target, polymorphic: true

  FORMAT = /\A[a-zA-Z0-9][a-zA-Z0-9_-]{0,63}\z/
  RESERVED = %w[assets uploads rails cable favicon robots sitemap health health_check install_links].freeze

  validates :path, presence: true, format: { with: FORMAT }, uniqueness: { case_sensitive: false }
  validates :target_type, inclusion: { in: %w[Scheme Channel] }

  def self.lookup(path)
    find_by('lower(path) = ?', path.to_s.downcase)
  end

  def self.reserved?(path)
    routes = Rails.application.routes.routes.filter_map do |route|
      route.path.spec.to_s.match(%r{\A/([a-zA-Z0-9_-]+)(?:/|\(|\z)})&.captures&.first
    end
    (RESERVED + routes).any? { |name| name.casecmp?(path.to_s) }
  end

  def self.available?(path, target: nil)
    return false unless path.to_s.match?(FORMAT) && !reserved?(path)

    existing = lookup(path)
    existing.nil? || existing.target == target
  end

  def self.generate_code
    loop do
      code = "d#{SecureRandom.alphanumeric(7)}"
      return code if available?(code)
    end
  end

  def self.dispatch?(path)
    link = lookup(path)
    link && (link.target_type == 'Scheme' || link.target&.slug != path)
  end

  def self.claim!(path, target)
    link = lookup(path)
    return if link&.target == target

    create!(path: path, target: target)
  rescue ActiveRecord::RecordNotUnique, ActiveRecord::RecordInvalid
    target.errors.add(:install_alias, I18n.t('install_links.errors.unavailable'))
    raise ActiveRecord::RecordInvalid, target
  end
end
