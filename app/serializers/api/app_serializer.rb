# frozen_string_literal: true

class Api::AppSerializer < ApplicationSerializer
  attributes :id, :name, :archived, :group_id, :storage_profile_id, :inherit_group_permissions

  has_many :schemes
  has_many :collaborators
end
