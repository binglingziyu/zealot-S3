# frozen_string_literal: true

class AuditEvent < ApplicationRecord
  belongs_to :user, optional: true
  validates :action, :subject_type, :subject_id, presence: true

  def self.record!(user:, action:, subject:, details: {})
    create!(user: user, action: action, subject_type: subject.class.name, subject_id: subject.id.to_s, details: details)
  end
end
