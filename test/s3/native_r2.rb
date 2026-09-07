# Real R2 checks on a production DB clone; only public fixture bytes are uploaded.
require 'net/http'
raise 'Explicit shadow DB required' unless ActiveRecord::Base.connection_db_config.database == 'zealot_shadow'
raise 'Disable all background execution and cron' unless GoodJob.configuration.execution_mode == :external && !Rails.application.config.good_job.enable_cron
raise 'Expected native amd64 runtime' unless RUBY_PLATFORM.include?('x86_64')
profile = StorageProfile.find_by!(system_default: true)
raise 'R2 profile required' unless profile.provider == 'r2'
user = User.admins.first!
apps = []
results = []
begin
  [['android.apk', 'android', 'package'], ['iphone.ipa', 'ios', 'package'], ['iOS-single-dSYM-with-single-macho.zip', 'ios', 'debug']].each do |filename, device, kind|
    app = App.create!(name: "Native R2 fixture #{SecureRandom.hex(8)}", storage_profile: profile)
    apps << app
    app.create_owner(user)
    channel = app.schemes.create!(name: 'Verification').channels.create!(name: device, device_type: device, bundle_id: '*')
    bytes = File.binread(File.join('/fixtures', filename))
    digest = Digest::SHA256.hexdigest(bytes)
    session = Uploads::Multipart.initiate(user: user, channel: channel, filename: filename, kind: kind,
      byte_size: bytes.bytesize, sha256: digest, idempotency_key: SecureRandom.uuid,
      metadata: { release_version: '1.0', build_version: '1' })
    service = Uploads::Multipart.new(session, actor: user)
    part = service.sign_parts([1]).first
    uri = URI(part.fetch(:url))
    response = Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 10, read_timeout: 120) do |http|
      request = Net::HTTP::Put.new(uri)
      request.body = bytes
      http.request(request)
    end
    raise "Upload failed: HTTP #{response.code}" unless response.is_a?(Net::HTTPSuccess)
    service.complete
    ProcessUploadJob.perform_now(session.id)
    session.reload
    raise "Parsing failed (#{session.state}): #{session.error_message}" unless session.state_ready?
    object = session.stored_object.reload
    raise 'Stored checksum mismatch' unless object.sha256 == digest
    actual = Digest::SHA256.new
    profile.client.get_object(bucket: profile.bucket, key: object.key) { |chunk| actual.update(chunk) }
    raise 'Download checksum mismatch' unless actual.hexdigest == digest
    published = kind == 'package' ? session.release : session.debug_file
    raise 'Metadata missing' unless kind == 'package' ? published.metadata.present? : published.metadata.exists?
    if filename == 'android.apk'
      icon = published.icon_object
      raise 'Icon binding mismatch' unless icon && icon.storage_profile_id == profile.id
      raise 'Icon empty' unless profile.client.head_object(bucket: profile.bucket, key: icon.key).content_length.positive?
    end
    ProcessUploadJob.perform_now(session.id)
    raise 'Duplicate release created' unless kind == 'debug' || channel.releases.count == 1
    results << { file: filename, bytes: bytes.bytesize, ready: true, sha256_matches: true, metadata: true }
  end
  puts JSON.generate(native: RUBY_PLATFORM, results: results)
ensure
  # These UUID objects belong only to newly-created fixture apps in the clone.
  objects = StoredObject.where(app: apps).to_a
  UploadSession.where(app: apps).delete_all
  apps.each(&:destroy!)
  objects.each do |object|
    profile.client.delete_object(bucket: profile.bucket, key: object.key)
    object.update!(state: 'purged')
  end
end
