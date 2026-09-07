require 'minitest/autorun'
require 'tmpdir'
require 'zip'
raise 'Disposable bucket required' unless ENV.fetch('ZEALOT_S3_BUCKET').start_with?('zealot-test-')

class BootstrapTest < Minitest::Test
  def test_backfill_preserves_bytes_and_roles_and_is_rerunnable
    profile = nil
    client = Zealot::Storage::S3.client
    begin
      client.create_bucket(bucket: Zealot::Storage::S3.bucket)
    rescue Aws::S3::Errors::BucketAlreadyOwnedByYou
    end
    owner = User.find_by!(email: ENV.fetch('ZEALOT_ADMIN_EMAIL'))
    app = App.create!(name: "Bootstrap #{SecureRandom.hex(8)}")
    app.create_owner(owner)
    developer = User.create!(username: 'bootstrap-developer', email: "bootstrap-#{SecureRandom.hex(5)}@test.invalid", password: SecureRandom.hex(20), role: 'developer', confirmed_at: Time.current)
    channel = app.schemes.create!(name: 'Bootstrap').channels.create!(name: 'Linux', device_type: 'linux', bundle_id: '*')
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'app.zip')
      Zip::File.open(path, create: true) { |z| z.get_output_stream('readme') { |f| f.write('bootstrap object bytes') } }
      session = ActionDispatch::Integration::Session.new(Rails.application)
      session.host!(ENV.fetch('ZEALOT_DOMAIN'))
      session.https!
      session.post('/api/apps/upload', params: { token: owner.token, channel_key: channel.key, file: Rack::Test::UploadedFile.new(path) })
      assert_equal 201, session.response.status
      release = channel.releases.first!
      old_key = release.file.file.key
      before_etag = client.head_object(bucket: Zealot::Storage::S3.bucket, key: old_key).etag
      profile = Storage::Bootstrap.call
      object = StoredObject.find(release.reload.package_object_id)
      assert_equal old_key, object.key
      assert_equal profile, object.storage_profile
      assert_equal Digest::SHA256.file(path).hexdigest, object.sha256
      assert_equal before_etag, client.head_object(bucket: profile.bucket, key: object.key).etag
      assert Access::AppAccess.allowed?(developer, app, action: :upload)
      assert app.reload.group.present?
      refute Collaborator.find_by!(app: app, user: owner).changed?
      assert Collaborator.find_by!(app: app, user: owner).owner?
      count = StoredObject.count
      Storage::Bootstrap.call
      assert_equal count, StoredObject.count
      assert_equal object.id, release.reload.package_object_id
      assert_equal 'zealot-test-only', profile.reload.credentials.fetch('secret_access_key')
    end
  ensure
    if app&.persisted?
      Release.where(channel_id: app.channel_ids).destroy_all
      StoredObject.where(app_id: app.id).delete_all
      group = app.reload.group
      app.destroy!
      group.destroy! if group && group.apps.empty?
    end
    developer&.destroy!
    profile&.destroy! if profile&.persisted? && profile.stored_objects.empty?
  end
end
