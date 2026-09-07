require_relative 'multipart'

class ObjectMigrationTest < MultipartTest
  def teardown
    ObjectMigration.where(source_object_id: @profile.stored_objects.select(:id)).delete_all
    super
  end

  def test_migration_recovers_after_copy_and_switches_all_artifact_kinds
    target = @profile.dup
    target.name = "Migration target #{@tag}"
    target.bucket = 'zealot-test-migration-target'
    target.save!
    @extra_profiles << target
    target.client.create_bucket(bucket: target.bucket)
    sources = %w[package icon debug].to_h do |kind|
      bytes = "#{kind} bytes #{@tag}"
      key = @profile.key("objects/#{SecureRandom.uuid}.bin")
      @profile.client.put_object(bucket: @profile.bucket, key: key, body: bytes)
      object = StoredObject.create!(storage_profile: @profile, app: @app, key: key, filename: "#{kind}.bin",
        kind: kind, state: 'ready', byte_size: bytes.bytesize, sha256: Digest::SHA256.hexdigest(bytes))
      [kind, object]
    end
    release = @channel.releases.new(package_object: sources['package'], icon_object: sources['icon'])
    release[:file] = 'package.bin'
    release[:icon] = 'icon.bin'
    release.save!(validate: false)
    DebugFile.insert_all!([{ app_id: @app.id, file: 'debug.bin', stored_object_id: sources['debug'].id,
      device_type: 'ios', checksum: SecureRandom.hex(16), created_at: Time.current, updated_at: Time.current }])
    debug = DebugFile.find_by!(app: @app)

    sources.each do |kind, source|
      migration = Storage::ObjectMover.start!(source_id: source.id, target_profile_id: target.id, actor: @user)
      interrupted = Storage::ObjectMover.new(migration)
      interrupted.define_singleton_method(:switch_references!) { |*| raise IOError, 'Simulated interruption after verified copy' }
      assert_raises(IOError) { interrupted.run }
      assert_equal 'failed', migration.reload.state
      assert_equal 'ready', source.reload.state
      current = kind == 'debug' ? debug.reload.stored_object_id : release.reload.public_send("#{kind}_object_id")
      assert_equal source.id, current

      Storage::ObjectMover.run(migration.id)
      assert_equal 'complete', migration.reload.state
      current = kind == 'debug' ? debug.reload.stored_object_id : release.reload.public_send("#{kind}_object_id")
      assert_equal migration.target_object_id, current
      migrated = migration.target_object.reload
      received = target.client.get_object(bucket: target.bucket, key: migrated.key).body.read
      assert_equal source.sha256, Digest::SHA256.hexdigest(received)
      assert_equal 'deleted', source.reload.state
      assert_operator source.purge_after, :>, 36.days.from_now
      assert_equal source.sha256, Digest::SHA256.hexdigest(@profile.client.get_object(bucket: @profile.bucket, key: source.key).body.read)
      assert_equal migration.id, Storage::ObjectMover.start!(source_id: source.id, target_profile_id: target.id, actor: @user).id
    end
    assert_equal @profile.id, @app.reload.effective_storage_profile.id
  end
end
