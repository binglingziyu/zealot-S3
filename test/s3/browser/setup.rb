# Disposable integration fixtures; never run against a production database.
raise 'Disposable bucket required' unless ENV.fetch('ZEALOT_S3_BUCKET').start_with?('zealot-test-')
user = User.find_by!(email: ENV.fetch('ZEALOT_ADMIN_EMAIL'))
tag = SecureRandom.hex(5)

def fixture_profile(name, prefix, public_endpoint: nil)
  profile = StorageProfile.find_or_initialize_by(name: name)
  profile.assign_attributes(region: ENV.fetch('ZEALOT_S3_REGION'), endpoint: ENV.fetch('ZEALOT_S3_ENDPOINT'),
    download_endpoint: public_endpoint, bucket: ENV.fetch('ZEALOT_S3_BUCKET'), prefix: prefix, force_path_style: true)
  profile.credentials = { access_key_id: ENV.fetch('ZEALOT_S3_ACCESS_KEY_ID'), secret_access_key: ENV.fetch('ZEALOT_S3_SECRET_ACCESS_KEY') }
  profile.save!
  profile
end

def fixture_channel(app_name, profile, user, device)
  app = App.find_or_create_by!(name: app_name) { |a| a.storage_profile = profile }
  app.create_owner(user) unless app.collaborators.exists?(user: user)
  app.schemes.find_or_create_by!(name: 'Integration').channels.find_or_create_by!(name: device) do |channel|
    channel.device_type = device
    channel.bundle_id = '*'
  end
end

profile = fixture_profile('Browser direct integration', 'browser-direct-integration', public_endpoint: 'http://127.0.0.1:18903')
android = fixture_channel("Browser direct #{tag}", profile, user, 'android')
ios = fixture_channel("Browser direct #{tag}", profile, user, 'ios')
linux = fixture_channel("Browser direct #{tag}", profile, user, 'linux')
# The sample dSYM and IPA have different bundle IDs. Keep their apps separate.
debug = fixture_channel("Browser debug #{tag}", profile, user, 'ios')
routes = Rails.application.routes.url_helpers
File.write('/tmp/browser-fixture.json', JSON.generate({ app_id: android.app.id,
  android_path: routes.new_channel_release_path(android), ios_path: routes.new_channel_release_path(ios),
  linux_path: routes.new_channel_release_path(linux), debug_key: debug.key }))

ci_profile = fixture_profile('Fastlane action integration', 'fastlane-action-integration')
ci = fixture_channel('Fastlane action integration', ci_profile, user, 'android')
File.write('/tmp/fastlane-fixture.json', JSON.generate({ endpoint: 'http://127.0.0.1:3001', token: user.token,
  channel_key: ci.key, file: Rails.root.join('test/s3/fixtures/android.apk').to_s,
  idempotency_key: 'fastlane-action-integration', wait_timeout: 180 }), perm: 0600)
