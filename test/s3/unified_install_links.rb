# frozen_string_literal: true
require 'minitest/autorun'
require 'warden/test/helpers'
require 'nokogiri'

raise 'Disposable database required' unless ActiveRecord::Base.connection_db_config.configuration_hash[:host] == 'zealot-s3-test-db'

class UnifiedInstallLinksTest < Minitest::Test
  include Warden::Test::Helpers

  ANDROID = 'Mozilla/5.0 (Linux; Android 15; Pixel 9) AppleWebKit/537.36 Chrome/130 Mobile Safari/537.36'
  IPHONE = 'Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 Mobile/15E148 Safari/604.1'
  IPAD = 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15) AppleWebKit/605.1.15 Mobile/15E148 Safari/604.1'
  DESKTOP = 'Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/537.36 Chrome/130 Safari/537.36'

  def setup
    Warden.test_mode!
    ActiveRecord::Base.connection.begin_transaction(joinable: false)
    @tag = SecureRandom.hex(5)
    @user = User.create!(username: "links-#{@tag}", email: "links-#{@tag}@test.invalid",
                         password: SecureRandom.hex(20), role: :member, confirmed_at: Time.current)
    @group = Group.create!(name: "Links #{@tag}")
    GroupMembership.create!(user: @user, group: @group, role: :admin)
    @app = App.create!(name: "Sensitive app #{@tag}", group: @group, inherit_group_permissions: true)
    @scheme = @app.schemes.create!(name: 'Beta')
    @android = @scheme.channels.create!(name: 'Android', device_type: :android, share_mode: :public)
    @ios = @scheme.channels.create!(name: 'iOS', device_type: :ios, share_mode: :public)
    @browser = ActionDispatch::Integration::Session.new(Rails.application)
    @browser.host!(ENV.fetch('ZEALOT_DOMAIN'))
    @browser.https!
  end

  def teardown
    Warden.test_reset!
    ActiveRecord::Base.connection.rollback_transaction
  end

  def path
    "/#{@scheme.preferred_install_path}"
  end

  def get(url = path, agent: DESKTOP)
    @browser.get(url, headers: { 'User-Agent' => agent })
    @browser.response
  end

  def assert_redirect(channel, agent, url = path)
    response = get(url, agent: agent)
    assert_equal 302, response.status, response.body[0, 500]
    assert_equal "/#{channel.slug}", URI(response.location).path
    assert_includes response.headers['Cache-Control'], 'no-store'
    assert_includes response.headers['Vary'], 'User-Agent'
  end

  def release(channel, version: '9.9-secret')
    now = Time.current
    result = Release.insert_all!([{ channel_id: channel.id, version: channel.releases.count + 1,
      release_version: version, build_version: 'secret-build-77', source: 'test', device_type: channel.device_type,
      name: "Sensitive release #{@tag}", changelog: [], custom_fields: [], created_at: now, updated_at: now }])
    Release.find(result.rows.first.first)
  end

  def test_existing_channels_and_schemes_are_backfilled_by_migration
    channel = Channel.find_by!(name: 'Legacy Android')
    assert_equal channel, PublicLink.lookup(channel.slug).target
    assert channel.scheme.install_code.present?
    assert_equal channel.scheme, PublicLink.lookup(channel.scheme.install_code).target
    assert_equal 200, get("/#{channel.slug}").status
    assert_equal 200, get("/#{channel.scheme.install_code}").status
  end

  def test_android_iphone_and_ipad_use_correct_latest_channel
    assert_redirect(@android, ANDROID)
    assert_redirect(@ios, IPHONE)
    assert_redirect(@ios, IPAD)
  end

  def test_desktop_has_both_platforms_qrcode_and_stable_url
    response = get
    assert_equal 200, response.status, response.body[0, 500]
    html = Nokogiri::HTML(response.body)
    assert html.at_css("a[href='/#{@android.slug}']")
    assert html.at_css("a[href='/#{@ios.slug}']")
    assert html.at_css("img[src='/install_links/#{@scheme.install_code}/qrcode?size=large']")
    assert_equal "https://#{ENV.fetch('ZEALOT_DOMAIN')}#{path}", html.at_css('#public-install-url')['value']
  end

  def test_custom_alias_and_fixed_code_both_work_on_all_devices
    code = @scheme.install_code
    @scheme.update!(install_alias: "ZOCharge-#{@tag}")
    ["/#{code}", path, path.downcase].each do |url|
      assert_redirect(@android, ANDROID, url)
      assert_redirect(@ios, IPHONE, url)
      assert_equal 200, get(url).status
    end
  end

  def test_changing_or_clearing_alias_keeps_previous_links
    first = "First-#{@tag}"
    second = "Second-#{@tag}"
    @scheme.update!(install_alias: first)
    @scheme.update!(install_alias: second)
    @scheme.update!(install_alias: '')
    [first, second, @scheme.install_code].each { |slug| assert_redirect(@android, ANDROID, "/#{slug}") }
  end

  def test_channel_alias_and_previous_slug_keep_working
    original = @android.slug
    @android.update!(install_alias: "channel-#{@tag}")
    assert_redirect(@android, ANDROID, "/#{@android.install_alias}")
    assert_equal 200, get("/#{original}").status
    @android.update!(slug: "new-channel-#{@tag}")
    assert_redirect(@android, ANDROID, "/#{original}")
    assert_equal 200, get("/#{@android.slug}").status
  end

  def test_channel_short_link_still_renders_without_redirect
    assert_equal 200, get("/#{@android.slug}").status
  end

  def test_latest_version_changes_do_not_change_entry_link
    code = @scheme.install_code
    release(@android, version: '1.0.0')
    assert_includes get.body, '1.0.0'
    release(@android, version: '2.0.0')
    assert_includes get.body, '2.0.0'
    refute_includes get.body, '1.0.0'
    assert_equal code, @scheme.reload.install_code
  end

  def test_unique_namespace_includes_old_channel_slugs_and_aliases
    refute @scheme.update(install_alias: @android.slug.swapcase)
    @scheme.reload.update!(install_alias: "Unique-#{@tag}")
    refute @android.update(install_alias: "unique-#{@tag}")
    refute @ios.update(slug: @scheme.install_code)
    assert_equal @scheme, PublicLink.lookup("UNIQUE-#{@tag}").target
  end

  def test_reserved_and_invalid_paths_are_rejected_without_partial_save
    %w[apps API users install_links assets health bad/name bad.name -first a?b].each do |slug|
      refute @scheme.update(install_alias: slug), slug
      assert_nil @scheme.reload.install_alias
    end
    refute @scheme.update(install_alias: 'a' * 65)
    assert @scheme.reload.update(install_alias: "valid_Name-#{@tag}")
  end

  def test_permanent_code_cannot_be_changed
    code = @scheme.install_code
    refute @scheme.update(install_code: "changed-#{@tag}")
    assert_equal code, @scheme.reload.install_code
  end

  def test_channel_selection_rejects_other_scheme_and_wrong_platform
    other = @app.schemes.create!(name: 'Production')
    channel = other.channels.create!(name: 'Android', device_type: :android)
    refute @scheme.update(android_channel: channel)
    refute @scheme.reload.update(android_channel: @ios)
    refute @scheme.reload.update(ios_channel_id: 99999999)
    assert @scheme.reload.update(android_channel: @android, ios_channel: @ios)
  end

  def test_multiple_same_platform_channels_require_explicit_selection
    second = @scheme.channels.create!(name: 'Android China', device_type: :android, share_mode: :public)
    response = get(agent: ANDROID)
    assert_equal 200, response.status
    refute_includes response.body, "/#{@android.slug}"
    @scheme.update!(android_channel: second)
    assert_redirect(second, ANDROID)
  end

  def test_private_channel_is_not_exposed_or_used_as_mobile_fallback
    @ios.update!(share_mode: :private)
    response = get(agent: IPHONE)
    assert_equal 200, response.status
    refute_includes response.body, @ios.slug
    assert_includes response.body, "/#{@android.slug}"
    @android.update!(share_mode: :private)
    assert_equal 403, get.status
    refute_includes get.body, @app.name
  end

  def test_password_metadata_is_hidden_and_password_challenge_is_preserved
    @android.update!(share_mode: :password, share_password: 'test-password')
    @ios.update!(share_mode: :private)
    r = release(@android)
    response = get
    assert_equal 200, response.status
    [@app.name, r.name, r.release_version, r.build_version].each { |value| refute_includes response.body, value }
    assert_redirect(@android, ANDROID)
    response = get("/#{@android.slug}")
    assert_equal 200, response.status
    assert Nokogiri::HTML(response.body).at_css('input[type="password"]')
    refute_includes response.body, r.release_version
  end

  def test_member_can_use_private_channels_and_locked_member_cannot
    @android.update!(share_mode: :private)
    @ios.update!(share_mode: :private)
    login_as(@user, scope: :user)
    assert_redirect(@ios, IPHONE)
    @user.update!(locked_at: Time.current)
    response = get
    assert_equal 302, response.status
    assert_equal '/users/sign_in', URI(response.location).path
  end

  def test_archived_application_and_deleted_links_are_unavailable
    @app.update!(archived: true)
    assert_equal 404, get.status
    assert_equal 404, get("/install_links/#{@scheme.install_code}/qrcode").status
    @app.update!(archived: false)
    code = @scheme.install_code
    alias_path = "deleted-#{@tag}"
    @scheme.update!(install_alias: alias_path)
    @app.destroy!
    assert_nil PublicLink.lookup(code)
    assert_nil PublicLink.lookup(alias_path)
    assert_equal 404, get("/#{alias_path}").status
  end

  def test_qrcode_is_png_for_alias_and_default_code
    @scheme.update!(install_alias: "qr-#{@tag}")
    [@scheme.install_code, @scheme.install_alias].each do |slug|
      response = get("/install_links/#{slug}/qrcode?size=large")
      assert_equal 200, response.status
      assert_equal 'image/png', response.media_type
      assert response.body.b.start_with?("\x89PNG".b)
    end
    @android.update!(share_mode: :private)
    @ios.update!(share_mode: :private)
    assert_equal 403, get("/install_links/#{@scheme.install_code}/qrcode").status
  end

  def test_explicit_choice_can_override_mobile_automatic_redirect
    response = get("#{path}?choose=1", agent: IPHONE)
    assert_equal 200, response.status
    assert_includes response.body, "/#{@android.slug}"
    assert_includes response.body, "/#{@ios.slug}"
  end

  def test_group_admin_can_save_settings_and_sees_validation_errors
    login_as(@user, scope: :user)
    @browser.get("/apps/#{@app.id}/schemes/#{@scheme.id}/edit")
    assert_equal 200, @browser.response.status
    assert_includes @browser.response.body, 'scheme_install_alias'
    token = Nokogiri::HTML(get('/apps').body).at_css('meta[name="csrf-token"]')['content']
    @browser.patch("/apps/#{@app.id}/schemes/#{@scheme.id}", params: {
      authenticity_token: token, scheme: { install_alias: "ui-#{@tag}", android_channel_id: @android.id } })
    assert_equal 302, @browser.response.status
    assert_equal "ui-#{@tag}", @scheme.reload.install_alias
    @browser.patch("/apps/#{@app.id}/schemes/#{@scheme.id}", params: {
      authenticity_token: token, scheme: { install_alias: 'apps' } })
    assert_equal 422, @browser.response.status
    assert_equal "ui-#{@tag}", @scheme.reload.install_alias
    @browser.get("/apps/#{@app.id}/schemes/#{@scheme.id}/channels/#{@android.id}/edit")
    assert_equal 200, @browser.response.status
    assert_includes @browser.response.body, 'channel_install_alias'
  end

  def test_unrelated_user_cannot_modify_or_claim_alias
    outsider = User.create!(username: "other-#{@tag}", email: "other-#{@tag}@test.invalid",
                            password: SecureRandom.hex(20), role: :member, confirmed_at: Time.current)
    login_as(outsider, scope: :user)
    token = Nokogiri::HTML(get('/apps').body).at_css('meta[name="csrf-token"]')['content']
    @browser.patch("/apps/#{@app.id}/schemes/#{@scheme.id}", params: {
      authenticity_token: token, scheme: { install_alias: "stolen-#{@tag}" } })
    assert_equal 403, @browser.response.status
    assert_nil PublicLink.lookup("stolen-#{@tag}")
  end

  def test_api_accepts_aliases_and_rejects_conflicts
    @browser.patch("/api/schemes/#{@scheme.id}", params: { install_alias: "api-#{@tag}", android_channel_id: @android.id },
      headers: { 'Authorization' => "Bearer #{@user.token}" }, as: :json)
    assert_equal 200, @browser.response.status, @browser.response.body[0, 500]
    assert_equal "api-#{@tag}", @scheme.reload.install_alias
    assert_equal "/api-#{@tag}", @browser.response.parsed_body['install_path']
    @browser.patch("/api/channels/#{@android.id}", params: { install_alias: "api-#{@tag}" },
      headers: { 'Authorization' => "Bearer #{@user.token}" }, as: :json)
    assert_equal 422, @browser.response.status
  end

  def test_database_prevents_case_insensitive_path_races
    assert_raises(ActiveRecord::RecordNotUnique) do
      PublicLink.transaction(requires_new: true) do
        PublicLink.insert_all!([{ path: @android.slug.swapcase, target_type: 'Scheme', target_id: @scheme.id,
          created_at: Time.current, updated_at: Time.current }])
      end
    end
    assert_equal @android, PublicLink.lookup(@android.slug).target
  end

  def test_removing_selected_channel_clears_binding_and_all_its_aliases
    @scheme.update!(android_channel: @android)
    @android.update!(install_alias: "removed-#{@tag}")
    slug = @android.slug
    @android.destroy!
    assert_nil @scheme.reload.android_channel_id
    assert_nil PublicLink.lookup(slug)
    assert_nil PublicLink.lookup("removed-#{@tag}")
    assert_redirect(@ios, IPHONE)
    response = get(agent: ANDROID)
    assert_equal 200, response.status
    refute_includes response.body, slug
  end
end
