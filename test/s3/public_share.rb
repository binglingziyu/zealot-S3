# frozen_string_literal: true
require 'minitest/autorun'
require 'tmpdir'
require 'zip'
require 'nokogiri'
require 'warden/test/helpers'
raise 'Disposable bucket required' unless ENV.fetch('ZEALOT_S3_BUCKET').start_with?('zealot-test-')

class PublicShareTest < Minitest::Test
  include Warden::Test::Helpers

  def setup
    @tag = SecureRandom.hex(6)
    @owner = User.find_by!(email: ENV.fetch('ZEALOT_ADMIN_EMAIL'))
    @profile = StorageProfile.create!(
      name: "Share store #{@tag}", provider: 'minio', region: ENV.fetch('ZEALOT_S3_REGION'),
      bucket: ENV.fetch('ZEALOT_S3_BUCKET'), endpoint: ENV.fetch('ZEALOT_S3_ENDPOINT'),
      force_path_style: true, prefix: "share-#{@tag}"
    )
    @profile.credentials = {
      access_key_id: ENV.fetch('ZEALOT_S3_ACCESS_KEY_ID'),
      secret_access_key: ENV.fetch('ZEALOT_S3_SECRET_ACCESS_KEY')
    }
    @profile.save!
    @group = Group.create!(name: "Share #{@tag}")
    @app = App.create!(name: "Share app #{@tag}", group: @group, storage_profile: @profile)
    @app.create_owner(@owner)
    @channel = @app.schemes.create!(name: 'Public').channels.create!(name: 'Linux', device_type: 'linux', bundle_id: '*')
    @browser = ActionDispatch::Integration::Session.new(Rails.application)
    @browser.host!(ENV.fetch('ZEALOT_DOMAIN'))
    @browser.https!
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'public-share.zip')
      Zip::File.open(path, create: true) { |zip| zip.get_output_stream('readme') { |file| file.write('public share') } }
      @browser.post('/api/apps/upload', params: {
        token: @owner.token, channel_key: @channel.key, file: Rack::Test::UploadedFile.new(path)
      })
      assert_equal 201, @browser.response.status, @browser.response.body
    end
    @release = @channel.releases.first!
  end

  def teardown
    if @app
      objects = StoredObject.where(app: @app).to_a
      objects.each do |object|
        @profile.client.delete_object(bucket: @profile.bucket, key: object.key)
      end
      UploadSession.where(app: @app).delete_all
      StoredObject.where(id: objects.map(&:id)).update_all(app_id: nil)
    end
    @app&.destroy!
    StoredObject.where(id: objects.map(&:id)).delete_all if objects
    @group&.destroy!
    @profile&.destroy!
  end

  def test_public_and_password_install_pages
    latest_path = Rails.application.routes.url_helpers.friendly_channel_releases_path(@channel)
    release_path = Rails.application.routes.url_helpers.friendly_channel_release_path(@channel, @release)

    @browser.get(release_path)
    assert_equal 302, @browser.response.status
    assert_includes @browser.response.location, '/users/sign_in'

    @channel.update!(share_mode: 'public')
    @browser.get(latest_path)
    assert_equal 200, @browser.response.status
    assert_includes @browser.response.body, @app.name
    assert_includes @browser.response.body, @release.download_url

    @channel.update!(share_mode: 'password', share_password: 'visit-1234')
    refute @channel.update(share_password: '123')
    @channel.reload
    refute_includes @channel.as_json.to_s, 'visit-1234'
    refute_includes @channel.as_json.to_s, 'share_password_digest'
    @browser.get(release_path)
    assert_equal 200, @browser.response.status
    assert_includes @browser.response.body, 'name="password"'
    refute_includes @browser.response.body, @app.name
    refute_includes @browser.response.body, @release.download_url
    csrf = Nokogiri::HTML(@browser.response.body).at_css('input[name="authenticity_token"]')['value']
    @browser.get(Rails.application.routes.url_helpers.channel_release_qrcode_path(@channel, @release))
    assert_equal 403, @browser.response.status
    @browser.get(@release.download_url)
    assert_equal 302, @browser.response.status
    assert_includes @browser.response.location, @channel.slug

    @browser.post(Rails.application.routes.url_helpers.auth_channel_release_path(@channel, @release),
      params: { password: 'wrong', authenticity_token: csrf })
    assert_equal 422, @browser.response.status
    csrf = Nokogiri::HTML(@browser.response.body).at_css('input[name="authenticity_token"]')['value']
    @browser.post(Rails.application.routes.url_helpers.auth_channel_release_path(@channel, @release),
      params: { password: 'visit-1234', authenticity_token: csrf })
    assert_equal 303, @browser.response.status
    @browser.get(release_path)
    assert_equal 200, @browser.response.status
    assert_includes @browser.response.body, @app.name

    @browser.get(@release.download_url)
    assert_equal 302, @browser.response.status
    @browser.follow_redirect!
    assert_equal 302, @browser.response.status
    assert_equal URI(ENV.fetch('ZEALOT_S3_ENDPOINT')).host, URI(@browser.response.location).host
    @browser.get(Rails.application.routes.url_helpers.channel_release_qrcode_path(@channel, @release))
    assert_equal 200, @browser.response.status

    @channel.update!(share_password: 'changed-5678')
    @browser.get(release_path)
    assert_includes @browser.response.body, 'name="password"'
    refute_includes @browser.response.body, @app.name
    refute_includes @browser.response.body, @release.download_url
    @browser.get(@release.download_url)
    assert_includes @browser.response.location, @channel.slug

    Warden.test_mode!
    login_as(@owner, scope: :user)
    admin = ActionDispatch::Integration::Session.new(Rails.application)
    admin.host!(ENV.fetch('ZEALOT_DOMAIN'))
    admin.https!
    edit_path = Rails.application.routes.url_helpers.edit_app_scheme_channel_path(
      @app, @channel.scheme, @channel
    )
    admin.get(edit_path)
    assert_equal 200, admin.response.status
    assert_includes admin.response.body, 'channel_share_mode'
    assert_includes admin.response.body, 'value="public"'
    assert_includes admin.response.body, 'value="password"'
    assert_includes admin.response.body, 'channel_share_password'
    assert_includes admin.response.body, Rails.application.routes.url_helpers.friendly_channel_releases_url(@channel)
    update_path = Rails.application.routes.url_helpers.app_scheme_channel_path(@app, @channel.scheme, @channel)
    admin_csrf = Nokogiri::HTML(admin.response.body)
      .at_css("form[action='#{update_path}'] input[name='authenticity_token']")['value']
    admin.patch(update_path,
      params: { authenticity_token: admin_csrf, channel: { share_mode: 'public', share_password: '' } })
    assert_equal 302, admin.response.status
    assert @channel.reload.share_public?

    empty_channel = @app.schemes.first.channels.create!(
      name: 'Empty public', device_type: 'windows', bundle_id: '*', share_mode: 'public'
    )
    anonymous = ActionDispatch::Integration::Session.new(Rails.application)
    anonymous.host!(ENV.fetch('ZEALOT_DOMAIN'))
    anonymous.https!
    anonymous.get(Rails.application.routes.url_helpers.friendly_channel_releases_path(empty_channel))
    assert_equal 200, anonymous.response.status
    assert_includes anonymous.response.body, I18n.t('channels.show.no_public_release')
  end

  def after_teardown
    Warden.test_reset!
  end
end
