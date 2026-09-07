# frozen_string_literal: true
class UploadSessionsController < ApplicationController
  include UploadSessionActions
  before_action :authenticate_user!
  before_action :set_upload, except: :create
  rescue_from ArgumentError, with: :invalid_upload
end
