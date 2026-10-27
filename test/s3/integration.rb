# Run only against the disposable integration database and bucket.
require 'minitest/autorun'
require 'net/http'
require 'uri'
require 'tmpdir'
require 'zip'

raise 'Refusing non-test bucket' unless ENV.fetch('ZEALOT_S3_BUCKET').start_with?('zealot-test-')

class S3IntegrationTest < Minitest::Test
  def setup
    @client = Zealot::Storage::S3.client
    @dir = Dir.mktmpdir('zealot-s3-test')
    @app = App.create!(name: "S3 integration #{SecureRandom.hex(4)}")
    @user = User.find_by!(email: ENV.fetch('ZEALOT_ADMIN_EMAIL'))
    @app.create_owner(@user)
    scheme = @app.schemes.create!(name: 'S3')
    @channel = scheme.channels.create!(name: 'Linux', device_type: 'linux', bundle_id: '*')
    @payload = File.join(@dir, 'test.zip')
    Zip::File.open(@payload, create: true) { |zip| zip.get_output_stream('test.txt') { |f| f.write('S3 integration payload') } }
  end

  def teardown
    @app&.destroy!
    FileUtils.rm_rf(@dir)
  end

  def upload(path = @payload)
    session = ActionDispatch::Integration::Session.new(Rails.application)
    session.host! ENV.fetch('ZEALOT_DOMAIN')
    session.https!
    session.post('/api/apps/upload', params: {
      token: @user.token, channel_key: @channel.key,
      file: Rack::Test::UploadedFile.new(path, 'application/octet-stream')
    })
    assert_equal 201, session.response.status, session.response.body[0, 1000]
    @channel.releases.reload.order(id: :desc).first!
  end

  def test_upload_download_ranges_missing_objects_and_delete
    release = upload.reload
    assert release.file.remote_storage?
    assert release.file?
    assert_equal '.zip', release.file_extname
    key = release.file.file.key
    assert_equal File.size(@payload), release.size
    refute File.exist?(Rails.root.join('public', release.file.path))

    session = ActionDispatch::Integration::Session.new(Rails.application)
    session.host! ENV.fetch('ZEALOT_DOMAIN')
    session.https!
    session.get(release.download_url)
    assert_equal 302, session.response.status
    session.follow_redirect!
    assert_equal 302, session.response.status
    url = URI(session.response.location)
    assert_equal 'zealot-s3-test-store', url.host
    assert_includes url.query, 'X-Amz-Signature'
    assert_equal 'private, no-store', session.response.headers['Cache-Control']
    response = Net::HTTP.get_response(url)
    assert_equal '200', response.code, response.body[0, 1000]
    assert_equal Digest::SHA256.file(@payload).hexdigest, Digest::SHA256.hexdigest(response.body)
    assert_includes response['content-disposition'], 'attachment'
    request = Net::HTTP::Get.new(url)
    request['Range'] = 'bytes=0-7'
    partial = Net::HTTP.start(url.host, url.port) { |http| http.request(request) }
    assert_equal '206', partial.code
    assert_equal File.binread(@payload, 8), partial.body

    private_url = url.dup
    private_url.query = nil
    assert_equal '403', Net::HTTP.get_response(private_url).code
    expired_url = Aws::S3::Presigner.new(client: @client).presigned_url(
      :get_object, bucket: Zealot::Storage::S3.bucket, key: key,
      expires_in: 1, time: Time.now - 120
    )
    refute_equal '200', Net::HTTP.get_response(URI(expired_url)).code

    temporary = nil
    release.file.with_local_file do |path|
      temporary = path
      assert_equal File.binread(@payload), File.binread(path)
    end
    refute File.exist?(temporary)
    assert_raises(RuntimeError) { release.file.with_local_file { |path| temporary = path; raise 'parser failed' } }
    refute File.exist?(temporary)

    release.destroy!
    assert_raises(Aws::S3::Errors::NotFound) { @client.head_object(bucket: Zealot::Storage::S3.bucket, key: key) }
  end

  def test_channel_password_protects_both_download_routes
    release = upload
    @channel.update!(share_mode: 'password', share_password: 'test-password')
    session = ActionDispatch::Integration::Session.new(Rails.application)
    session.host! ENV.fetch('ZEALOT_DOMAIN')
    session.https!
    [release.download_url, Rails.application.routes.url_helpers.filename_download_release_url(release, release.download_filename)].each do |url|
      session.get(url)
      assert_equal 302, session.response.status
      refute_includes session.response.location, 'X-Amz-Signature'
      assert_includes session.response.location, @channel.slug
    end
  end

  def test_missing_object_returns_404_not_a_broken_signed_url
    release = upload
    release.file.file.delete
    session = ActionDispatch::Integration::Session.new(Rails.application)
    session.host! ENV.fetch('ZEALOT_DOMAIN')
    session.https!
    session.get(release.download_url)
    assert_equal 404, session.response.status
  end

  def test_remote_checksum_and_debug_file_parse
    # The APK mapping archive layout recognized by app-info's Proguard parser.
    mapping = File.join(@dir, 'mapping.zip')
    Zip::File.open(mapping, create: true) do |zip|
      zip.get_output_stream('mapping.txt') { |f| f.write("com.example.App -> a:\n") }
      zip.get_output_stream('AndroidManifest.xml') { |f| f.write('<manifest package="com.example.app" versionName="1.0" versionCode="1"/>') }
    end
    debug = @app.debug_files.new(device_type: 'android', release_version: '1.0', build_version: '1')
    File.open(mapping, 'rb') { |f| debug.file = f; debug.save! }
    debug.reload
    assert debug.file.remote_storage?
    assert debug.file?
    assert_equal Digest::MD5.file(mapping).hexdigest, debug.file.checksum
    DebugFileTeardownJob.perform_now(debug)
    assert debug.reload.metadata.exists?
    assert_equal 'com.example.app', debug.proguard.object
    debug.update!(build_version: '2')
    assert debug.reload.file?
    session = ActionDispatch::Integration::Session.new(Rails.application)
    session.host! ENV.fetch('ZEALOT_DOMAIN')
    session.https!
    session.get('/api/debug_files/download', params: {
      channel_key: @channel.key, release_version: '1.0', build_version: '2'
    })
    assert_equal 302, session.response.status
    session.follow_redirect!
    assert_equal 302, session.response.status
    session.follow_redirect!
    assert_equal 302, session.response.status
    object_url = URI(session.response.location)
    assert_equal 'zealot-s3-test-store', object_url.host
    assert_equal File.binread(mapping), Net::HTTP.get(object_url)
    key = debug.file.file.key
    debug.destroy!
    assert_raises(Aws::S3::Errors::NotFound) { @client.head_object(bucket: Zealot::Storage::S3.bucket, key: key) }
  end

  def test_real_android_and_ios_packages_and_async_reparse
    { 'android' => 'android.apk', 'ios' => 'iphone.ipa' }.each do |platform, filename|
      @channel.update!(device_type: platform)
      release = upload(File.join(__dir__, 'fixtures', filename)).reload
      assert_equal platform, release.platform.downcase
      assert release.bundle_id.present?
      assert release.release_version.present?
      assert release.file.remote_storage?
      assert release.icon.remote_storage? if release.icon.present?
      TeardownJob.perform_now(release.id, @user.id)
      assert release.reload.metadata.present?, "#{platform} remote teardown produced no metadata"
      release.parse!(nil, 'reparse')
      assert release.bundle_id.present?
      if platform == 'ios'
        @channel.update!(share_mode: 'password', share_password: 'ios-secret')
        release.reload
        session = ActionDispatch::Integration::Session.new(Rails.application)
        session.host! ENV.fetch('ZEALOT_DOMAIN')
        session.https!
        manifest_url = URI.decode_www_form(URI(release.install_url).query).to_h.fetch('url')
        session.get(manifest_url)
        assert_equal 200, session.response.status
        plist = Plist.parse_xml(session.response.body)
        package_url = plist['items'][0]['assets'].find { |a| a['kind'] == 'software-package' }['url']
        assert_equal 'zealot-s3-test-store', URI(package_url).host
        assert_equal File.binread(File.join(__dir__, 'fixtures', filename)), Net::HTTP.get(URI(package_url))
        session.get(manifest_url.split('?').first)
        assert_equal 403, session.response.status
        @channel.update!(share_password: 'rotated-secret')
        session.get(manifest_url)
        assert_equal 403, session.response.status
      end
    end
  end

  def test_dsym_parser_uses_remote_file
    debug = @app.debug_files.new(device_type: 'ios')
    File.open(File.join(__dir__, 'fixtures', 'iOS-single-dSYM-with-single-macho.zip')) do |f|
      debug.file = f
      debug.save!
    end
    debug.reload
    DebugFileTeardownJob.perform_now(debug)
    assert debug.reload.metadata.exists?
    assert debug.file.remote_storage?
    assert debug.metadata.first.uuid.present?
  end

  def test_large_file_multipart_upload
    path = File.join(@dir, 'large.bin')
    File.open(path, 'wb') { |f| f.truncate(105 * 1024 * 1024) }
    object = Zealot::Storage::S3::File.new("uploads/apps/a#{@app.id}/multipart.bin")
    object.store!(CarrierWave::SanitizedFile.new(path))
    assert_equal File.size(path), object.size
    checksum = Digest::SHA256.new
    @client.get_object(bucket: Zealot::Storage::S3.bucket, key: object.key) { |chunk| checksum.update(chunk) }
    assert_equal Digest::SHA256.file(path).hexdigest, checksum.hexdigest
  ensure
    object&.delete
  end

  def test_failed_s3_upload_does_not_commit_a_release
    original_bucket = ENV.fetch('ZEALOT_S3_BUCKET')
    ENV['ZEALOT_S3_BUCKET'] = 'zealot-test-nonexistent-bucket'
    before = Release.count
    record = @channel.releases.new
    File.open(@payload) { |f| record.file = f }
    assert_raises(Aws::S3::Errors::NoSuchBucket) { record.save! }
    assert_equal before, Release.count
  ensure
    ENV['ZEALOT_S3_BUCKET'] = original_bucket
  end

  def test_permission_errors_are_not_reported_as_missing_files
    denied = Aws::S3::Client.new(region: 'us-east-1', stub_responses: true)
    denied.stub_responses(:head_object, 'AccessDenied')
    object = Zealot::Storage::S3::File.new('uploads/denied.zip', client: denied)
    assert_raises(Aws::S3::Errors::AccessDenied) { object.exists? }
    assert_raises(Aws::S3::Errors::AccessDenied) { object.size }
  end

  def test_backup_roundtrip_reads_objects_from_s3
    release = upload
    backup = Zealot::Backup::Uploads.new(@dir)
    backup.dump(app_ids: :all)
    assert File.size(File.join(@dir, 'uploads.tar.gz')).positive?
    release.file.file.delete
    backup.restore
    assert release.reload.file?
    assert_equal File.binread(@payload), Net::HTTP.get(URI(release.file.signed_download_url(filename: 'restored.zip')))
  end

  def test_migration_export_and_icon_storage
    release = upload
    # A PNG icon can be served directly from a private bucket via signed URL.
    png = Base64.decode64('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aZ1sAAAAASUVORK5CYII=')
    icon = File.join(@dir, 'icon.png')
    File.binwrite(icon, png)
    File.open(icon) { |f| release.icon = f; release.save! }
    release.reload
    assert release.icon.remote_storage?
    assert_equal png, Net::HTTP.get(URI(release.icon.url))
    exported = File.join(@dir, 'export')
    Zealot::Storage::Transfer.export_to(exported, app_ids: [@app.id])
    assert File.file?(File.join(exported, release.file.path.delete_prefix('uploads/')))
    release.file.file.delete
    Zealot::Storage::Transfer.import_from(exported)
    assert release.reload.file?
  end
end
