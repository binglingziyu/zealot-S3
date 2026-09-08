# Production acceptance: creates only a disposable app and UUID R2 objects.
require 'net/http'
require 'nokogiri'
require 'tmpdir'
require 'zip'

raise 'Production database required' unless ActiveRecord::Base.connection_db_config.database == 'zealot'
raise 'Expected release image' unless ENV['ZEALOT_VCS_REF'] == '1f8e5ea8'
raise 'External jobs required for controlled acceptance' unless GoodJob.configuration.execution_mode == :external

profile = StorageProfile.find_by!(system_default: true)
admin = User.admins.first!
original = { apps: App.pluck(:id), users: User.pluck(:id), channels: Channel.pluck(:id) }
app = App.create!(name: "Public share acceptance #{SecureRandom.hex(6)}", storage_profile: profile)
app.create_owner(admin)
channel = app.schemes.create!(name: 'Public').channels.create!(
  name: 'Linux', device_type: 'linux', bundle_id: '*', share_mode: 'public'
)
objects = []

begin
  Dir.mktmpdir('zealot-public-share-') do |directory|
    path = File.join(directory, 'public-share.zip')
    Zip::File.open(path, create: true) do |zip|
      zip.get_output_stream('readme.txt') { |file| file.write('production public share acceptance') }
    end
    bytes = File.binread(path)
    digest = Digest::SHA256.hexdigest(bytes)
    upload = Uploads::Multipart.initiate(
      user: admin, channel: channel, filename: File.basename(path), kind: 'package',
      byte_size: bytes.bytesize, sha256: digest, idempotency_key: SecureRandom.uuid,
      metadata: { release_version: '1.0', build_version: '1', changelog: 'Temporary acceptance' }
    )
    service = Uploads::Multipart.new(upload, actor: admin)
    part = service.sign_parts([1]).first
    uri = URI(part.fetch(:url))
    response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == 'https') do |http|
      request = Net::HTTP::Put.new(uri)
      request.body = bytes
      http.request(request)
    end
    raise "R2 upload failed: #{response.code}" unless response.is_a?(Net::HTTPSuccess)
    service.complete
    ProcessUploadJob.perform_now(upload.id)
    upload.reload
    raise "Parse failed: #{upload.error_message}" unless upload.state_ready?
    release = upload.release
    objects = StoredObject.where(app: app).to_a

    origin = URI('https://zealot.dev.ihubin.com')
    page_uri = URI.join(origin.to_s, "/#{channel.slug}")
    page = Net::HTTP.start(page_uri.host, page_uri.port, use_ssl: true,
      verify_mode: OpenSSL::SSL::VERIFY_NONE) { |http| http.get(page_uri.request_uri) }
    raise "Public page failed: #{page.code}" unless page.code == '200' && page.body.include?(app.name)

    package_uri = URI(release.file.signed_download_url(filename: release.download_filename))
    raise 'Expected public R2 URL' unless package_uri.host == 'infra.s3.mockdata.work' && package_uri.query.nil?
    package = Net::HTTP.get_response(package_uri)
    raise "Public package failed: #{package.code}" unless package.code == '200'
    raise 'Public package SHA mismatch' unless Digest::SHA256.hexdigest(package.body) == digest

    password = "accept-#{SecureRandom.hex(8)}"
    channel.update!(share_mode: 'password', share_password: password)
    browser = ActionDispatch::Integration::Session.new(Rails.application)
    browser.host! ENV.fetch('ZEALOT_DOMAIN')
    browser.https!
    browser.get("/#{channel.slug}")
    raise 'Password page leaked app details' unless browser.response.status == 200 &&
      !browser.response.body.include?(app.name) && browser.response.body.include?('name="password"')
    csrf = Nokogiri::HTML(browser.response.body).at_css('input[name="authenticity_token"]')['value']
    browser.post(Rails.application.routes.url_helpers.auth_channel_release_path(channel, release),
      params: { password: password, authenticity_token: csrf })
    raise 'Password unlock failed' unless browser.response.status == 303
    browser.get("/#{channel.slug}")
    raise 'Unlocked page missing app' unless browser.response.status == 200 && browser.response.body.include?(app.name)
    channel.update!(share_password: "changed-#{SecureRandom.hex(8)}")
    browser.get("/#{channel.slug}")
    raise 'Old authorization survived password change' if browser.response.body.include?(app.name)

    puts JSON.generate(
      public_page: page_uri.to_s, public_status: page.code, password_locked: true,
      password_unlock: true, password_rotation_revoked: true,
      package_host: package_uri.host, package_sha256: true
    )
  end
ensure
  UploadSession.where(app: app).delete_all
  objects.each { |object| profile.client.delete_object(bucket: profile.bucket, key: object.key) }
  StoredObject.where(app: app).update_all(app_id: nil)
  app.destroy!
  StoredObject.where(id: objects.map(&:id)).delete_all
  raise 'Production records changed' unless App.pluck(:id).sort == original[:apps].sort &&
    User.pluck(:id).sort == original[:users].sort && Channel.pluck(:id).sort == original[:channels].sort
end
