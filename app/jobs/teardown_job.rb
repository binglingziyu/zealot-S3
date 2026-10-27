# frozen_string_literal: true

class TeardownJob < ApplicationJob
  queue_as :app_parse

  def perform(release_id, user_id)
    actor = User.find_by(id: user_id)
    raise Pundit::NotAuthorizedError unless Access::AppAccess.allowed?(actor, release(id: release_id).app, action: :upload)
    return unless file = determine_file!(release_id)

    metadata = file.with_local_file { |path| TeardownService.new(path, release: release(id: release_id), user: User.find_by(id: user_id)).call }
    unless metadata
      logger.error "Unable to parse metadata with release: #{release_id}"
      return
    end

    metadata.update_attribute(:user_id, user_id) if user_id.present?
    update_release_resouces(release_id, metadata)
  rescue AppInfo::UnknownFormatError
    # ignore
  end

  private

  def update_release_resouces(release_id, metadata)
    return if release_id.blank?

    metadata.update_attribute(:release_id, release_id)
    release = release(id: release_id)
    release.update(release_type: metadata.release_type) if release.release_type.blank?
  end

  def determine_file!(release_id)
    release = release(id: release_id)
    file = release&.file
    unless file && file.stored_file_exists?
      logger.error('File was not found, it had been clean or deleted')
      return
    end

    file
  end

  def release(id: release_id)
    @release ||= Release.find(id)
  end
end
