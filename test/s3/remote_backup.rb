require_relative 'multipart'
raise 'External jobs required' unless GoodJob.configuration.execution_mode == :external

class RemoteBackupTest < MultipartTest
  def test_remote_backup_job_ui_download_and_retention
    backup = Backup.create!(key: "remote-#{@tag}", schedule: '0 0 * * *', max_keeps: 1,
      enabled: false, enabled_database: false, enabled_apps: [@app.id], storage_profile: @profile)
    BackupJob.perform_now(backup.id)
    file = backup.backup_files.fetch(0)
    assert file.basename.end_with?('.dump')
    assert file.size.positive?
    assert_equal file.sha256, @profile.stored_objects.find_by!(kind: 'backup').sha256
    data = @profile.client.get_object(bucket: @profile.bucket, key: file.manifest.fetch('key')).body.read
    assert_equal 'PGDMP', data.byteslice(0, 5)
    assert_equal file.sha256, Digest::SHA256.hexdigest(data)
    assert_raises(ArgumentError) { backup.destroy_directory(file.basename) }
    backup.storage_profile_id = nil
    refute backup.save
    backup.reload

    Warden.test_mode!
    login_as(@user, scope: :user)
    browser = ActionDispatch::Integration::Session.new(Rails.application)
    browser.host! ENV.fetch('ZEALOT_DOMAIN')
    browser.https!
    routes = Rails.application.routes.url_helpers
    browser.get(routes.admin_backup_path(backup))
    assert_equal 200, browser.response.status
    assert_includes browser.response.body, file.basename
    browser.get(routes.archive_admin_backup_path(backup, key: file.basename))
    assert_equal 302, browser.response.status
    assert_equal Digest::SHA256.hexdigest(data), Digest::SHA256.hexdigest(Net::HTTP.get(URI(browser.response.location)))
    browser.get(routes.edit_admin_backup_path(backup))
    assert_equal 200, browser.response.status
    assert_includes browser.response.body, 'backup_storage_profile_id'
  ensure
    if backup&.persisted?
      # Disposable test data only; bypass production retention for cleanup.
      @profile.client.list_objects_v2(bucket: @profile.bucket, prefix: @profile.key("database-backups/#{backup.id}/")).each do |page|
        page.contents.each { |entry| @profile.client.delete_object(bucket: @profile.bucket, key: entry.key) }
      end
      backup.destroy!
    end
  end
end
