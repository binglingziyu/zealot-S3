require 'minitest/autorun'
require 'net/http'
require 'warden/test/helpers'
require 'nokogiri'
raise 'Disposable bucket required' unless ENV.fetch('ZEALOT_S3_BUCKET').start_with?('zealot-test-')

class MultipartTest < Minitest::Test
  include Warden::Test::Helpers
  def setup
    @extra_users = []
    @extra_apps = []
    @extra_profiles = []
    @tag = SecureRandom.hex(6)
    @user = User.find_by!(email: ENV.fetch('ZEALOT_ADMIN_EMAIL'))
    @profile = StorageProfile.create!(name: "Multipart #{@tag}", region: ENV.fetch('ZEALOT_S3_REGION'), endpoint: ENV.fetch('ZEALOT_S3_ENDPOINT'), bucket: ENV.fetch('ZEALOT_S3_BUCKET'), prefix: "multipart-#{@tag}", force_path_style: true)
    @profile.credentials = { access_key_id: ENV.fetch('ZEALOT_S3_ACCESS_KEY_ID'), secret_access_key: ENV.fetch('ZEALOT_S3_SECRET_ACCESS_KEY') }
    @profile.save!
    begin
      @profile.client.create_bucket(bucket: @profile.bucket)
    rescue Aws::S3::Errors::BucketAlreadyOwnedByYou
    end
    @app = App.create!(name: "Multipart #{@tag}", storage_profile: @profile)
    @app.create_owner(@user)
    @channel = @app.schemes.create!(name: 'Direct').channels.create!(name: 'Linux', device_type: 'linux')
  end

  def teardown
    Warden.test_reset!
    apps = [@app] + @extra_apps
    UploadSession.where(app: apps).find_each do |session|
      begin
        @profile.client.abort_multipart_upload(bucket: @profile.bucket, key: session.stored_object.key, upload_id: session.multipart_upload_id) if session.multipart_upload_id
      rescue Aws::S3::Errors::NoSuchUpload
      end
    end
    ([@profile] + @extra_profiles).each { |p| p.stored_objects.each { |object| p.client.delete_object(bucket: p.bucket, key: object.key) } }
    UploadSession.where(app: apps).delete_all
    DebugFile.where(app: apps).destroy_all
    Release.where(channel_id: apps.flat_map(&:channel_ids)).destroy_all
    StoredObject.where(storage_profile: [@profile] + @extra_profiles).delete_all
    apps.each(&:destroy!)
    @profile.reload.destroy!
    @extra_profiles.each { |p| p.reload.destroy! }
    @extra_users.each(&:destroy!)
  end

  def initiate(bytes, key: SecureRandom.uuid)
    Uploads::Multipart.initiate(user: @user, channel: @channel, filename: 'app.zip', byte_size: bytes.bytesize, sha256: Digest::SHA256.hexdigest(bytes), idempotency_key: key)
  end

  def put(part, body)
    url = URI(part.fetch(:url))
    request = Net::HTTP::Put.new(url)
    request.body = body
    Net::HTTP.start(url.host, url.port, use_ssl: url.scheme == 'https') { |http| http.request(request) }
  end

  def test_direct_parts_complete_bytes_and_no_rewrite_after_completion
    bytes = 'direct-package-' * 1_300_000 # >16MiB: exercise two real parts
    session = initiate(bytes, key: 'two-parts')
    assert_equal session.id, initiate(bytes, key: 'two-parts').id
    service = Uploads::Multipart.new(session, actor: @user)
    parts = service.sign_parts([1, 2])
    assert_equal 2, parts.size
    parts.each_with_index do |part, index|
      assert_equal '200', put(part, bytes.byteslice(index * session.part_size, part[:byte_size])).code
    end
    assert_equal 'uploaded', service.complete.state
    assert_equal 'uploaded', service.complete.state
    object = session.stored_object.reload
    downloaded = @profile.client.get_object(bucket: @profile.bucket, key: object.key).body.read
    assert_equal Digest::SHA256.hexdigest(bytes), Digest::SHA256.hexdigest(downloaded)
    refute_equal '200', put(parts.first, bytes.byteslice(0, session.part_size)).code
    assert_raises(ArgumentError) { service.sign_parts([1]) }
    assert_equal @profile.id, object.storage_profile_id
  end

  def test_completion_reconciles_a_cloud_success_before_db_commit
    bytes = 'reconcile'
    session = initiate(bytes)
    service = Uploads::Multipart.new(session, actor: @user)
    assert_equal '200', put(service.sign_parts([1]).first, bytes).code
    client = @profile.client
    parts = client.list_parts(bucket: @profile.bucket, key: session.stored_object.key, upload_id: session.multipart_upload_id).parts
    client.complete_multipart_upload(bucket: @profile.bucket, key: session.stored_object.key, upload_id: session.multipart_upload_id,
      multipart_upload: { parts: parts.map { |p| { part_number: p.part_number, etag: p.etag } } })
    assert_equal 'uploaded', service.complete.state
  end

  def test_real_apk_is_parsed_without_reuploading_the_package
    @channel.update!(device_type: 'android', bundle_id: '*')
    bytes = File.binread(File.join(__dir__, 'fixtures/android.apk'))
    session = Uploads::Multipart.initiate(user: @user, channel: @channel, filename: 'android.apk', byte_size: bytes.bytesize,
      sha256: Digest::SHA256.hexdigest(bytes), idempotency_key: 'apk')
    service = Uploads::Multipart.new(session, actor: @user)
    assert_equal '200', put(service.sign_parts([1]).first, bytes).code
    service.complete
    object_id = session.stored_object_id
    other = @profile.dup
    other.name = "Other #{@tag}"
    other.bucket = 'zealot-test-second-bucket'
    other.save!
    @extra_profiles << other
    begin
      other.client.create_bucket(bucket: other.bucket)
    rescue Aws::S3::Errors::BucketAlreadyOwnedByYou
    end
    @app.update!(storage_profile: other)
    ProcessUploadJob.perform_now(session.id)
    assert_equal 'ready', session.reload.state, session.error_message
    release = session.release
    assert_equal object_id, release.package_object_id
    assert_equal 'Android', release.platform
    assert release.metadata.present?
    assert_equal @profile.id, release.icon_object.storage_profile_id
    assert_equal Digest::SHA256.hexdigest(bytes), session.stored_object.reload.sha256
    before = Release.where(channel: @channel).count
    ProcessUploadJob.perform_now(session.id)
    assert_equal before, Release.where(channel: @channel).count


  end

  def test_ipa_upload_and_manifest_ticket_use_bound_storage
    @channel.update!(device_type: 'ios', bundle_id: '*')
    bytes = File.binread(File.join(__dir__, 'fixtures/iphone.ipa'))
    session = Uploads::Multipart.initiate(user: @user, channel: @channel, filename: 'iphone.ipa', byte_size: bytes.bytesize,
      sha256: Digest::SHA256.hexdigest(bytes), idempotency_key: 'ipa')
    service = Uploads::Multipart.new(session, actor: @user)
    assert_equal '200', put(service.sign_parts([1]).first, bytes).code
    service.complete
    ProcessUploadJob.perform_now(session.id)
    assert_equal 'ready', session.reload.state, session.error_message
    release = session.release
    assert_equal 'iOS', release.platform
    assert_equal session.stored_object_id, release.package_object_id
    assert release.metadata.present?
    url = URI.decode_www_form(URI(release.install_url).query).to_h.fetch('url')
    browser = ActionDispatch::Integration::Session.new(Rails.application)
    browser.host! ENV.fetch('ZEALOT_DOMAIN')
    browser.https!
    browser.get(url)
    assert_equal 200, browser.response.status
    manifest = Plist.parse_xml(browser.response.body)
    asset = manifest['items'][0]['assets'].find { |a| a['kind'] == 'software-package' }
    assert_equal bytes, Net::HTTP.get(URI(asset['url']))

    ios_channel = @channel.scheme.channels.create!(name: 'Symbols', device_type: 'ios', bundle_id: '*')
    symbols = File.binread(File.join(__dir__, 'fixtures/iOS-single-dSYM-with-single-macho.zip'))
    rejected = Uploads::Multipart.initiate(user: @user, channel: ios_channel, filename: 'symbols.zip', kind: 'debug',
      byte_size: symbols.bytesize, sha256: Digest::SHA256.hexdigest(symbols), idempotency_key: "mismatched-#{@tag}")
    debug_service = Uploads::Multipart.new(rejected, actor: @user)
    assert_equal '200', put(debug_service.sign_parts([1]).first, symbols).code
    debug_service.complete
    ProcessUploadJob.perform_now(rejected.id)
    assert_equal 'failed', rejected.reload.state
    assert_includes rejected.error_message, 'Debug bundle IDs do not match'
    assert_nil rejected.debug_file_id
  end

  def test_checksum_mismatch_never_publishes
    bytes = 'wrong-hash'
    session = Uploads::Multipart.initiate(user: @user, channel: @channel, filename: 'bad.zip', byte_size: bytes.bytesize,
      sha256: '0' * 64, idempotency_key: 'bad-hash')
    service = Uploads::Multipart.new(session, actor: @user)
    put(service.sign_parts([1]).first, bytes)
    service.complete
    ProcessUploadJob.perform_now(session.id)
    assert_equal 'failed', session.reload.state
    assert_nil session.release_id
    assert_includes session.error_message, 'SHA256 mismatch'
  end

  def test_live_ruby_client_uploads_and_reuses_a_published_release
    skip 'Set ZEALOT_DIRECT_TEST_ENDPOINT to a disposable Rails server' unless ENV['ZEALOT_DIRECT_TEST_ENDPOINT']
    require Rails.root.join('clients/fastlane/lib/zealot_direct/client').to_s
    @channel.update!(device_type: 'android', bundle_id: '*')
    progress = []
    client = ZealotDirect::Client.new(endpoint: ENV.fetch('ZEALOT_DIRECT_TEST_ENDPOINT'),
      token: @user.token, wait_timeout: 180, progress: ->(part, total) { progress << [part, total] })
    options = { file: File.join(__dir__, 'fixtures/android.apk'), channel_key: @channel.key,
      idempotency_key: "live-#{@tag}", changelog: 'Direct client integration' }
    result = client.upload(**options)
    assert_equal 'ready', result.fetch('state')
    assert result.fetch('release_url').present?
    release = Release.find(result.fetch('release_id'))
    assert_equal [{ 'message' => 'Direct client integration' }], release.changelog
    assert_equal @profile.id, release.package_object.storage_profile_id
    assert_equal Digest::SHA256.file(options[:file]).hexdigest, release.package_object.sha256
    assert_equal [[1, 1]], progress
    repeated = client.upload(**options)
    assert_equal result.fetch('release_id'), repeated.fetch('release_id')
    assert_equal 1, @channel.releases.count
    assert_equal [[1, 1]], progress, 'Published uploads must not send package bytes again'
  end

  def test_live_ruby_client_resumes_a_previously_uploaded_part
    skip 'Set ZEALOT_DIRECT_TEST_ENDPOINT to a disposable Rails server' unless ENV['ZEALOT_DIRECT_TEST_ENDPOINT']
    require Rails.root.join('clients/fastlane/lib/zealot_direct/client').to_s
    @channel.update!(device_type: 'android', bundle_id: '*')
    path = File.join(__dir__, 'fixtures/android.apk')
    session = Uploads::Multipart.initiate(user: @user, channel: @channel, filename: File.basename(path),
      byte_size: File.size(path), sha256: Digest::SHA256.file(path).hexdigest, idempotency_key: "resume-#{@tag}")
    service = Uploads::Multipart.new(session, actor: @user)
    assert_equal '200', put(service.sign_parts([1]).first, File.binread(path)).code
    before = service.uploaded_parts
    assert_equal [1], before.map { |part| part[:part_number] }
    client = ZealotDirect::Client.new(endpoint: ENV.fetch('ZEALOT_DIRECT_TEST_ENDPOINT'), token: @user.token,
      wait_timeout: 180, progress: ->(*) { flunk 'A completed part must not be uploaded again' })
    result = client.upload(file: path, channel_key: @channel.key, idempotency_key: "resume-#{@tag}")
    assert_equal 'ready', result.fetch('state')
    assert_equal session.id, result.fetch('id')
    assert_equal 1, @channel.releases.count
  end

  def test_live_ruby_client_publishes_debug_symbols
    skip 'Set ZEALOT_DIRECT_TEST_ENDPOINT to a disposable Rails server' unless ENV['ZEALOT_DIRECT_TEST_ENDPOINT']
    require Rails.root.join('clients/fastlane/lib/zealot_direct/client').to_s
    @channel.update!(device_type: 'ios', bundle_id: '*')
    path = File.join(__dir__, 'fixtures/iOS-single-dSYM-with-single-macho.zip')
    client = ZealotDirect::Client.new(endpoint: ENV.fetch('ZEALOT_DIRECT_TEST_ENDPOINT'), token: @user.token, wait_timeout: 180)
    result = client.upload(file: path, channel_key: @channel.key, kind: 'debug',
      release_version: '1.0', build_version: '1', idempotency_key: "debug-#{@tag}")
    assert_equal 'ready', result.fetch('state')
    debug = DebugFile.find(result.fetch('debug_file_id'))
    assert debug.metadata.exists?
    assert_equal @profile.id, debug.stored_object.storage_profile_id
    assert_equal Digest::SHA256.file(path).hexdigest, debug.stored_object.sha256
    assert_nil result.fetch('release_id')

    other = App.create!(name: "Other symbols #{@tag}", storage_profile: @profile)
    @extra_apps << other
    other.create_owner(@user)
    channel = other.schemes.create!(name: 'Other').channels.create!(name: 'iOS', device_type: 'ios', bundle_id: '*')
    repeated = client.upload(file: path, channel_key: channel.key, kind: 'debug',
      release_version: '1.0', build_version: '1', idempotency_key: "debug-other-#{@tag}")
    assert_equal 'ready', repeated.fetch('state')
    second = DebugFile.find(repeated.fetch('debug_file_id'))
    assert_equal other.id, second.app_id
    assert_equal debug.checksum, second.checksum
    refute_equal debug.stored_object_id, second.stored_object_id
  end

  def test_live_ruby_client_sends_multiple_parts
    skip 'Set ZEALOT_DIRECT_TEST_ENDPOINT to a disposable Rails server' unless ENV['ZEALOT_DIRECT_TEST_ENDPOINT']
    require Rails.root.join('clients/fastlane/lib/zealot_direct/client').to_s
    Tempfile.create(['direct-linux-', '.bin']) do |file|
      file.binmode
      20.times { file.write('x' * 1024**2) }
      file.flush
      progress = []
      client = ZealotDirect::Client.new(endpoint: ENV.fetch('ZEALOT_DIRECT_TEST_ENDPOINT'), token: @user.token,
        wait_timeout: 180, concurrency: 3, progress: ->(part, total) { progress << [part, total] })
      result = client.upload(file: file.path, channel_key: @channel.key, idempotency_key: "large-#{@tag}")
      assert_equal 'ready', result.fetch('state')
      assert_equal [[1, 2], [2, 2]], progress.sort
      release = Release.find(result.fetch('release_id'))
      assert_equal Digest::SHA256.file(file.path).hexdigest, release.package_object.sha256
      assert_equal 20 * 1024**2, release.package_object.byte_size
    end
  end

  def test_browser_control_requests_require_csrf_and_render_direct_forms
    Warden.test_mode!
    login_as(@user, scope: :user)
    browser = ActionDispatch::Integration::Session.new(Rails.application)
    browser.host! ENV.fetch('ZEALOT_DOMAIN')
    browser.https!
    browser.get(Rails.application.routes.url_helpers.new_channel_release_path(@channel))
    assert_equal 200, browser.response.status
    document = Nokogiri::HTML(browser.response.body)
    assert document.at_css('form[data-controller="direct-upload"]')
    refute_includes browser.response.body, @user.token
    token = document.at_css('meta[name="csrf-token"]')['content']
    values = { channel_key: @channel.key, filename: 'browser.zip', byte_size: 5, idempotency_key: "browser-#{@tag}" }
    browser.post('/upload_sessions', params: values, as: :json)
    assert_equal 422, browser.response.status
    browser.post('/upload_sessions', params: values, headers: { 'X-CSRF-Token' => token }, as: :json)
    assert_equal 201, browser.response.status, browser.response.body[0, 300]
    id = browser.response.parsed_body.fetch('id')
    browser.post("/upload_sessions/#{id}/parts", params: { part_numbers: [1] }, headers: { 'X-CSRF-Token' => token }, as: :json)
    assert_equal 200, browser.response.status
    assert_equal '200', put(browser.response.parsed_body.fetch('parts').first.symbolize_keys, 'hello').code
    browser.get("/upload_sessions/#{id}/parts", as: :json)
    assert_equal 5, browser.response.parsed_body.fetch('parts').first.fetch('byte_size')
    browser.delete("/upload_sessions/#{id}", headers: { 'X-CSRF-Token' => token }, as: :json)
    assert_equal 'cancelled', browser.response.parsed_body.fetch('state')
    browser.get(Rails.application.routes.url_helpers.new_debug_file_path)
    assert_equal 200, browser.response.status
    assert Nokogiri::HTML(browser.response.body).at_css('form[data-direct-upload-kind-value="debug"]')
  end

  def test_incomplete_upload_and_reused_idempotency_key_are_rejected
    session = initiate('hello', key: 'same')
    service = Uploads::Multipart.new(session, actor: @user)
    service.sign_parts([1])
    assert_raises(ArgumentError) { service.complete }
    assert_raises(ArgumentError) { initiate('different', key: 'same') }
    assert_equal 'cancelled', service.cancel.state
    assert_equal 'cancelled', service.cancel.state
    assert_raises(ArgumentError) { service.sign_parts([1]) }
  end

  def test_other_uploaders_cannot_take_over_sessions_and_revocation_prevents_publication
    users = 2.times.map do |index|
      user = User.create!(username: "direct-#{@tag}-#{index}", email: "direct-#{@tag}-#{index}@test.invalid",
        password: SecureRandom.hex(20), confirmed_at: Time.current, role: :member)
      @extra_users << user
      Collaborator.create!(user: user, app: @app, role: :developer)
      user
    end
    owner, other = users
    session = Uploads::Multipart.initiate(user: owner, channel: @channel, filename: 'permission.zip',
      byte_size: 5, sha256: Digest::SHA256.hexdigest('hello'), idempotency_key: "permission-#{@tag}")
    attacker = Uploads::Multipart.new(session, actor: other)
    assert_raises(Pundit::NotAuthorizedError) { attacker.sign_parts([1]) }
    assert_raises(Pundit::NotAuthorizedError) { attacker.uploaded_parts }
    assert_raises(Pundit::NotAuthorizedError) { attacker.complete }
    assert_raises(Pundit::NotAuthorizedError) { attacker.cancel }
    service = Uploads::Multipart.new(session, actor: owner)
    assert_equal '200', put(service.sign_parts([1]).first, 'hello').code
    service.complete
    Collaborator.find_by!(user: owner, app: @app).destroy!
    assert_raises(Pundit::NotAuthorizedError) { service.complete }
    ProcessUploadJob.perform_now(session.id)
    assert_equal 'failed', session.reload.state
    assert_nil session.release_id
    assert_includes session.error_message, 'permission was revoked'
  end
end
