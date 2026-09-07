require 'minitest/autorun'
require 'minitest/mock'
raise 'Disposable bucket required' unless ENV.fetch('ZEALOT_S3_BUCKET').start_with?('zealot-test-')

class ReconciliationTest < Minitest::Test
  def setup
    @tag = SecureRandom.hex(6)
    @profile = StorageProfile.create!(name: "Reconcile #{@tag}", endpoint: ENV.fetch('ZEALOT_S3_ENDPOINT'),
      region: ENV.fetch('ZEALOT_S3_REGION'), bucket: ENV.fetch('ZEALOT_S3_BUCKET'), prefix: "reconcile-#{@tag}", force_path_style: true)
    @profile.credentials = { access_key_id: ENV.fetch('ZEALOT_S3_ACCESS_KEY_ID'), secret_access_key: ENV.fetch('ZEALOT_S3_SECRET_ACCESS_KEY') }
    @profile.save!
    @client = @profile.client
    @app = App.create!(name: "Reconcile #{@tag}", storage_profile: @profile)
    @user = User.find_by!(email: ENV.fetch('ZEALOT_ADMIN_EMAIL'))
    @app.create_owner(@user)
    @channel = @app.schemes.create!(name: 'Test').channels.create!(name: 'Linux', device_type: 'linux')
    @profiles = [@profile]
    @multipart = []
    @previous_recovery = ENV['ZEALOT_RECOVERY_MODE']
  end

  def teardown
    @previous_recovery.nil? ? ENV.delete('ZEALOT_RECOVERY_MODE') : ENV['ZEALOT_RECOVERY_MODE'] = @previous_recovery
    @multipart += UploadSession.where(app: @app).where.not(multipart_upload_id: nil).map { |session| [session.stored_object.key, session.multipart_upload_id] }
    @multipart.each do |name, id|
      @client.abort_multipart_upload(bucket: @profile.bucket, key: name, upload_id: id)
    rescue Aws::S3::Errors::NoSuchUpload
    end
    @client.list_multipart_uploads(bucket: @profile.bucket, prefix: @profile.prefix).each do |page|
      page.uploads.each { |upload| @client.abort_multipart_upload(bucket: @profile.bucket, key: upload.key, upload_id: upload.upload_id) }
    end
    @client.list_objects_v2(bucket: @profile.bucket, prefix: @profile.prefix).each do |page|
      page.contents.each { |object| @client.delete_object(bucket: @profile.bucket, key: object.key) }
    end
    UploadSession.where(app: @app).delete_all
    Release.where(channel: @channel).delete_all
    StoredObject.where(storage_profile: @profiles).delete_all
    @app.destroy!
    @profiles.each { |profile| profile.reload.destroy! }
  end

  def key
    @profile.key("objects/#{SecureRandom.uuid}.bin")
  end

  def object(state: 'ready', kind: 'package')
    name = key
    @client.put_object(bucket: @profile.bucket, key: name, body: 'retained bytes')
    StoredObject.create!(app: @app, storage_profile: @profile, key: name, filename: 'retained.bin', kind: kind, state: state)
  end

  def test_unknown_old_parts_are_aborted_but_known_and_unmanaged_parts_survive
    orphan_key = key
    StoredObject.create!(app: @app, storage_profile: @profile, key: orphan_key, filename: 'orphan.bin', kind: 'package')
    orphan = @client.create_multipart_upload(bucket: @profile.bucket, key: orphan_key)
    @multipart << [orphan_key, orphan.upload_id]
    @client.upload_part(bucket: @profile.bucket, key: orphan_key, upload_id: orphan.upload_id, part_number: 1, body: 'orphan part')
    unrelated_key = @profile.key('objects/manual-file.bin')
    unrelated = @client.create_multipart_upload(bucket: @profile.bucket, key: unrelated_key)
    @multipart << [unrelated_key, unrelated.upload_id]
    session = Uploads::Multipart.initiate(user: @user, channel: @channel, filename: 'known.bin', byte_size: 5, idempotency_key: @tag)
    Uploads::Multipart.new(session, actor: @user).sign_parts([1])
    Storage::Reconciler.new(@profile).call
    assert_includes @client.list_multipart_uploads(bucket: @profile.bucket, prefix: orphan_key).flat_map(&:uploads).map(&:key), orphan_key
    assert @client.list_parts(bucket: @profile.bucket, key: orphan_key, upload_id: orphan.upload_id)
    Storage::Reconciler.new(@profile, now: 3.days.from_now).call
    assert_raises(Aws::S3::Errors::NoSuchUpload) { @client.list_parts(bucket: @profile.bucket, key: orphan_key, upload_id: orphan.upload_id) }
    assert @client.list_parts(bucket: @profile.bucket, key: session.stored_object.key, upload_id: session.multipart_upload_id)
    assert @client.list_parts(bucket: @profile.bucket, key: unrelated_key, upload_id: unrelated.upload_id)
    assert_equal 'uploading', session.reload.state
  end

  def test_orphan_bytes_get_a_full_recovery_window_and_are_not_deleted
    orphan_key = key
    @client.put_object(bucket: @profile.bucket, key: orphan_key, body: 'orphan bytes')
    Storage::Reconciler.new(@profile).call
    refute StoredObject.exists?(key: orphan_key)
    Storage::Reconciler.new(@profile, now: 3.days.from_now).call
    tombstone = StoredObject.find_by!(key: orphan_key)
    assert_equal 'deleted', tombstone.state
    assert_operator tombstone.purge_after, :>, 36.days.from_now
    assert_equal 'orphan bytes', @client.get_object(bucket: @profile.bucket, key: orphan_key).body.read
    deleted_at = tombstone.deleted_at
    Storage::Reconciler.new(@profile, now: 3.days.from_now).call
    assert_equal 1, StoredObject.where(key: orphan_key).count
    assert_equal deleted_at, tombstone.reload.deleted_at
  end

  def test_other_profile_references_and_backups_are_preserved
    other = @profile.dup
    other.name = "Other #{@tag}"
    other.save!
    @profiles << other
    shared = object
    shared.update_columns(storage_profile_id: other.id)
    backup = object(kind: 'backup')
    unreferenced = object
    Storage::Reconciler.new(@profile, now: 3.days.from_now).call
    assert_equal 'ready', shared.reload.state
    assert_equal 'ready', backup.reload.state
    assert_equal 'deleted', unreferenced.reload.state
  end

  def test_recovery_mode_and_current_db_references_prevent_purge
    referenced = object
    removable = object
    [referenced, removable].each { |entry| entry.update_columns(state: 'deleted', deleted_at: 40.days.ago, purge_after: 1.day.ago) }
    Release.insert_all!([{ channel_id: @channel.id, package_object_id: referenced.id, file: 'retained.bin', changelog: [], version: 1, created_at: Time.current, updated_at: Time.current }])
    ENV['ZEALOT_RECOVERY_MODE'] = 'true'
    PurgeStoredObjectsJob.perform_now
    Storage::Reconciler.new(@profile, now: 3.days.from_now).call
    assert_equal 'deleted', removable.reload.state
    assert_equal 'retained bytes', @client.get_object(bucket: @profile.bucket, key: removable.key).body.read
    ENV.delete('ZEALOT_RECOVERY_MODE')
    PurgeStoredObjectsJob.perform_now
    assert_equal 'purged', removable.reload.state
    assert_raises(Aws::S3::Errors::NoSuchKey) { @client.get_object(bucket: @profile.bucket, key: removable.key) }
    assert_equal 'deleted', referenced.reload.state
    assert_equal 'retained bytes', @client.get_object(bucket: @profile.bucket, key: referenced.key).body.read
  end

  def test_failed_analysis_expires_after_a_retry_window_without_immediate_object_deletion
    expired = Uploads::Multipart.initiate(user: @user, channel: @channel, filename: 'old.bin', byte_size: 5, idempotency_key: "expired-#{@tag}")
    expired.update_columns(state: 'failed', attempts: 1, created_at: 10.days.ago, expires_at: 9.days.ago, heartbeat_at: 8.days.ago, updated_at: 8.days.ago)
    retryable = Uploads::Multipart.initiate(user: @user, channel: @channel, filename: 'retry.bin', byte_size: 5, idempotency_key: "retry-#{@tag}")
    retryable.update_columns(state: 'failed', attempts: 2, heartbeat_at: 10.minutes.ago, updated_at: 10.minutes.ago)
    scheduled = []
    ProcessUploadJob.stub(:perform_later, ->(id) { scheduled << id }) { ReconcileUploadsJob.perform_now }
    assert_equal 'expired', expired.reload.state
    assert_equal 'deleted', expired.stored_object.reload.state
    assert_operator expired.stored_object.purge_after, :>, 36.days.from_now
    refute_includes scheduled, expired.id
    assert_includes scheduled, retryable.id
    assert_equal 'failed', retryable.reload.state
  end
end
