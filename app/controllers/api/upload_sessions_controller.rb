# frozen_string_literal: true
class Api::UploadSessionsController < Api::BaseController
  include UploadSessionActions
  before_action :validate_user_token
  before_action :set_upload, except: :create
  rescue_from ArgumentError, with: :invalid_upload
end
