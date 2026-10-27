require 'minitest/autorun'
require 'warden/test/helpers'
require 'nokogiri'
raise 'Disposable bucket required' unless ENV.fetch('ZEALOT_S3_BUCKET').start_with?('zealot-test-')

class ManagementUiTest < Minitest::Test
  include Warden::Test::Helpers

  def setup
    Warden.test_mode!
    @tag = SecureRandom.hex(6)
    @admin = User.find_by!(email: ENV.fetch('ZEALOT_ADMIN_EMAIL'))
    @user = User.create!(username: "ui-#{@tag}", email: "ui-#{@tag}@test.invalid", password: SecureRandom.hex(20), confirmed_at: Time.current)
    @session = ActionDispatch::Integration::Session.new(Rails.application)
    @session.host!(ENV.fetch('ZEALOT_DOMAIN'))
    @session.https!
    login_as(@admin, scope: :user)
  end

  def teardown
    Warden.test_reset!
    AuditEvent.where(user_id: [@admin.id, @user.id]).delete_all
    @app&.destroy!
    @group&.destroy!
    @profile&.destroy!
    @user&.destroy!
  end

  def csrf(path)
    @session.get(path)
    assert_equal 200, @session.response.status, @session.response.body[0, 300]
    Nokogiri::HTML(@session.response.body).at_css('meta[name="csrf-token"]')['content']
  end

  def test_group_management_and_member_visibility
    token = csrf('/groups/new')
    @session.post('/groups', params: { authenticity_token: token, group: { name: "UI group #{@tag}" } })
    assert_equal 302, @session.response.status
    @group = Group.find_by!(name: "UI group #{@tag}")
    token = csrf("/groups/#{@group.id}")
    @session.post("/groups/#{@group.id}/add_member", params: { authenticity_token: token, email: @user.email, role: 'viewer' })
    assert_equal 302, @session.response.status
    assert GroupMembership.exists?(group: @group, user: @user, role: 'viewer')
    login_as(@user, scope: :user)
    @session.get("/groups/#{@group.id}")
    assert_equal 200, @session.response.status
    refute_includes @session.response.body, '保存授权'
    @session.get("/groups/#{@group.id}/edit")
    assert_equal 403, @session.response.status
  end

  def test_storage_form_saves_encrypted_secrets_and_blocks_members
    token = csrf('/storage_profiles/new')
    @session.post('/storage_profiles', params: { authenticity_token: token, storage_profile: {
      name: "UI store #{@tag}", provider: 'r2', region: 'auto', bucket: 'test-private',
      endpoint: 'https://example.r2.cloudflarestorage.com', enabled: true,
      access_key_id: 'fake-ui-access', secret_access_key: 'fake-ui-secret', group_ids: [''], app_ids: ['']
    } })
    assert_equal 302, @session.response.status
    @profile = StorageProfile.find_by!(name: "UI store #{@tag}")
    assert_equal 'fake-ui-secret', @profile.credentials.fetch('secret_access_key')
    @session.get("/storage_profiles/#{@profile.id}/edit")
    assert_equal 200, @session.response.status
    refute_includes @session.response.body, 'fake-ui-secret'
    refute_includes @session.response.body, 'fake-ui-access'
    login_as(@user, scope: :user)
    @session.get('/storage_profiles')
    assert_equal 403, @session.response.status
  end

  def test_management_post_requires_csrf_token
    @session.get('/groups/new')
    @session.post('/groups', params: { group: { name: "Forged #{@tag}" } })
    assert_equal 422, @session.response.status
    refute Group.exists?(name: "Forged #{@tag}")
  end

  def test_group_developer_can_open_empty_debug_files_page_and_upload
    @group = Group.create!(name: "Debug UI group #{@tag}")
    @app = App.create!(name: "Debug UI app #{@tag}", group: @group, inherit_group_permissions: true)
    GroupMembership.create!(group: @group, user: @user, role: 'developer')
    login_as(@user, scope: :user)

    @session.get('/debug_files')

    assert_equal 200, @session.response.status, @session.response.body[0, 500]
    assert Nokogiri::HTML(@session.response.body).at_css('a[href="/debug_files/new"]')
  end
end
