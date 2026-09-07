require_relative 'multipart'

class ConcurrentStorageTest < MultipartTest
  def test_concurrent_profiles_keep_packages_and_icons_bound_after_default_changes
    second = @profile.dup
    second.name = "Concurrent #{@tag}"
    second.bucket = 'zealot-test-concurrent-second'
    second.save!
    @extra_profiles << second
    begin
      second.client.create_bucket(bucket: second.bucket)
    rescue Aws::S3::Errors::BucketAlreadyOwnedByYou
    end
    other_app = App.create!(name: "Concurrent second #{@tag}", storage_profile: second)
    other_app.create_owner(@user)
    @extra_apps << other_app
    channel2 = other_app.schemes.create!(name: 'Parallel').channels.create!(name: 'Android', device_type: 'android', bundle_id: '*')
    @channel.update!(device_type: 'android', bundle_id: '*')
    bytes = File.binread(File.join(__dir__, 'fixtures/android.apk'))
    hash = Digest::SHA256.hexdigest(bytes)
    barrier = Queue.new
    threads = [[@channel.id, @profile.id, second.id], [channel2.id, second.id, @profile.id]].map do |channel_id, profile_id, replacement_id|
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          channel = Channel.find(channel_id)
          actor = User.find(@user.id)
          session = Uploads::Multipart.initiate(user: actor, channel: channel, filename: 'android.apk', byte_size: bytes.bytesize,
            sha256: hash, idempotency_key: "concurrent-#{@tag}-#{channel_id}")
          barrier.pop
          service = Uploads::Multipart.new(session, actor: actor)
          response = put(service.sign_parts([1]).first, bytes)
          raise "Upload failed: #{response.code}" unless response.code == '200'
          service.complete
          # Defaults change while each fixed-location upload is waiting to parse.
          channel.app.update!(storage_profile_id: replacement_id)
          ProcessUploadJob.perform_now(session.id)
          session.reload
          raise "Parser state #{session.state}: #{session.error_message}" unless session.state_ready?
          [session.id, profile_id, replacement_id]
        end
      end
    end
    2.times { barrier << true }
    results = threads.map(&:value)
    assert_equal 2, results.size
    results.each do |session_id, expected_profile_id, replacement_id|
      session = UploadSession.find(session_id)
      assert_equal replacement_id, session.app.storage_profile_id
      release = session.release
      assert_equal 'Android', release.platform
      objects = [release.package_object, release.icon_object]
      objects.each do |object|
        assert_equal expected_profile_id, object.storage_profile_id
        data = object.storage_profile.client.get_object(bucket: object.storage_profile.bucket, key: object.key).body.read
        assert_equal object.sha256, Digest::SHA256.hexdigest(data)
      end
      assert_equal hash, release.package_object.sha256
      release.destroy!
      objects.each do |object|
        assert object.reload.state_deleted?
        assert_operator object.purge_after, :>, 36.days.from_now
        assert_operator object.storage_profile.client.head_object(bucket: object.storage_profile.bucket, key: object.key).content_length, :>, 0
      end
    end
  ensure
    threads&.each(&:join)
  end
end
