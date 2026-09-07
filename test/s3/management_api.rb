require 'minitest/autorun'
raise 'Disposable bucket required' unless ENV.fetch('ZEALOT_S3_BUCKET').start_with?('zealot-test-')

class ManagementApiTest < Minitest::Test
  def setup
    @tag = SecureRandom.hex(6)
    @admin = User.find_by!(email: ENV.fetch('ZEALOT_ADMIN_EMAIL'))
    @user = User.create!(username: "api-#{@tag}", email: "api-#{@tag}@test.invalid", password: SecureRandom.hex(20), confirmed_at: Time.current)
    @groups, @profiles, @apps = [], [], []
    @browser = ActionDispatch::Integration::Session.new(Rails.application)
    @browser.host! ENV.fetch('ZEALOT_DOMAIN')
    @browser.https!
  end

  def teardown
    @apps.each { |app| app.reload.destroy! }
    @groups.each { |group| group.reload.destroy! if Group.exists?(group.id) }
    @profiles.each { |profile| profile.reload.destroy! if StorageProfile.exists?(profile.id) }
    @user.destroy!
  end

  def request(method, path, values = {}, user: @admin, **attributes)
    values = values.merge(attributes)
    @browser.public_send(method, path, params: values, headers: { 'Authorization' => "Bearer #{user.token}" }, as: :json)
    @browser.response
  end

  def group(name = 'Managed')
    response = request(:post, '/api/groups', group: { name: "#{name} #{@tag}" })
    assert_equal 201, response.status, response.body
    value = Group.find(response.parsed_body.fetch('id'))
    @groups << value
    value
  end

  def profile
    response = request(:post, '/api/storage_profiles', storage_profile: { name: "Storage #{@tag}", provider: 'r2',
      bucket: "test-#{@tag}", region: 'auto', endpoint: 'https://example.r2.cloudflarestorage.com', enabled: true,
      access_key_id: 'fake-management-access', secret_access_key: 'fake-management-secret' })
    assert_equal 201, response.status, response.body
    value = StorageProfile.find(response.parsed_body.fetch('id'))
    @profiles << value
    value
  end

  def test_groups_members_and_revocation_are_scoped
    own = group
    hidden = group('Hidden')
    response = request(:post, "/api/groups/#{own.id}/add_member", { email: @user.email, role: 'admin' })
    assert_equal 200, response.status
    membership_id = response.parsed_body.fetch('id')
    response = request(:get, '/api/groups', {}, user: @user)
    assert_equal [own.id], response.parsed_body.map { |entry| entry.fetch('id') }
    assert_equal 404, request(:get, "/api/groups/#{hidden.id}", {}, user: @user).status
    assert_equal 200, request(:patch, "/api/groups/#{own.id}", { group: { description: 'Updated by group admin' } }, user: @user).status
    assert_equal 'Updated by group admin', own.reload.description
    assert_equal 200, request(:get, "/api/groups/#{own.id}/members", {}, user: @user).status
    assert_equal 403, request(:post, '/api/groups', { group: { name: 'Unauthorized' } }, user: @user).status
    before = own.reload.access_version
    assert_equal 204, request(:delete, "/api/groups/#{own.id}/members/#{membership_id}").status
    assert_operator own.reload.access_version, :>, before
    assert_equal 404, request(:get, "/api/groups/#{own.id}", {}, user: @user).status
  end

  def test_storage_secrets_are_write_only_and_rotation_preserves_grants
    store = profile
    refute_includes @browser.response.body, 'fake-management'
    refute_includes @browser.response.body, 'credentials_ciphertext'
    own = group
    request(:patch, "/api/storage_profiles/#{store.id}", storage_profile: { group_ids: [own.id] })
    assert_equal 200, @browser.response.status
    assert_equal 'fake-management-secret', store.reload.credentials.fetch('secret_access_key')
    previous = store.credentials_version
    response = request(:patch, "/api/storage_profiles/#{store.id}", storage_profile: { access_key_id: 'rotated-key', secret_access_key: 'rotated-secret' })
    assert_equal 200, response.status
    assert_operator response.parsed_body.fetch('credentials_version'), :>, previous
    refute_includes response.body, 'rotated-'
    assert_equal [own.id], store.storage_grants.pluck(:group_id)
    assert_equal 403, request(:get, '/api/storage_profiles', {}, user: @user).status
    assert_equal 403, request(:patch, "/api/storage_profiles/#{store.id}", { storage_profile: { enabled: false } }, user: @user).status
    assert store.reload.enabled?
  end

  def test_group_and_app_storage_choices_require_grants
    own = group
    store = profile
    GroupMembership.create!(group: own, user: @user, role: 'admin')
    response = request(:get, "/api/groups/#{own.id}/available_storage", {}, user: @user)
    refute_includes response.parsed_body.map { |entry| entry['id'] }, store.id
    assert_equal 403, request(:patch, "/api/groups/#{own.id}", { group: { storage_profile_id: store.id } }, user: @user).status
    request(:patch, "/api/storage_profiles/#{store.id}", storage_profile: { group_ids: [own.id] })
    assert_equal 200, @browser.response.status
    assert_equal 200, request(:patch, "/api/groups/#{own.id}", { group: { storage_profile_id: store.id } }, user: @user).status
    app = App.create!(name: "API app #{@tag}", group: own)
    @apps << app
    response = request(:get, "/api/apps/#{app.id}/available_storage", {}, user: @user)
    assert_equal 200, response.status
    assert_includes response.parsed_body.map { |entry| entry['id'] }, store.id
    refute_includes response.body, 'endpoint'
    refute_includes response.body, 'bucket'
    response = request(:patch, "/api/apps/#{app.id}", { storage_profile_id: store.id }, user: @user)
    assert_equal 200, response.status
    assert_equal store.id, response.parsed_body.fetch('storage_profile_id')
    assert_equal 422, request(:delete, "/api/groups/#{own.id}", {}, user: @user).status
    assert_equal 422, request(:delete, "/api/storage_profiles/#{store.id}").status
  end

  def test_bad_grants_roll_back_default_switch_and_credentials
    store = profile
    defaults = StorageProfile.where(system_default: true).pluck(:id)
    ciphertext = store.credentials_ciphertext
    response = request(:patch, "/api/storage_profiles/#{store.id}", storage_profile: {
      system_default: true, access_key_id: 'uncommitted-key', secret_access_key: 'uncommitted-secret', group_ids: [-1] })
    assert_equal 422, response.status
    assert_equal defaults, StorageProfile.where(system_default: true).pluck(:id)
    assert_equal ciphertext, store.reload.credentials_ciphertext
    assert_empty store.storage_grants
    assert_equal 422, request(:patch, "/api/storage_profiles/#{store.id}", storage_profile: { group_ids: 'invalid' }).status
  end
end
