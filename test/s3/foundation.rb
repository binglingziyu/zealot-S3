# frozen_string_literal: true
require 'minitest/autorun'
raise 'Disposable test environment required' unless ENV.fetch('ZEALOT_S3_BUCKET').start_with?('zealot-test-')

class FoundationTest < Minitest::Test
  def setup
    @tag = SecureRandom.hex(6)
    @groups = []
    @apps = []
    @users = []
    @profiles = []
  end

  def teardown
    UploadSession.where(app_id: @apps.map(&:id)).delete_all
    StoredObject.where(app_id: @apps.map(&:id)).delete_all
    @apps.reverse_each(&:destroy!)
    @groups.reverse_each(&:destroy!)
    @profiles.reverse_each(&:destroy!)
    @users.reverse_each(&:destroy!)
  end

  def user(role = 'member')
    @users << User.create!(username: "foundation-#{@tag}-#{@users.size}", email: "#{@tag}-#{@users.size}@test.invalid", password: SecureRandom.hex(20), role: role, confirmed_at: Time.current)
    @users.last
  end

  def group
    @groups << Group.create!(name: "Group #{@tag}-#{@groups.size}")
    @groups.last
  end

  def app(group: nil, inherit: true)
    @apps << App.create!(name: "App #{@tag}-#{@apps.size}", group: group, inherit_group_permissions: inherit)
    @apps.last
  end

  def profile
    @profiles << StorageProfile.create!(name: "Store #{@tag}-#{@profiles.size}", region: 'auto', bucket: 'private-test', endpoint: 'https://example.r2.cloudflarestorage.com')
    @profiles.last
  end

  def test_group_scope_and_direct_grants_do_not_leak
    u = user
    g = group
    inherited = app(group: g)
    isolated = app(group: g, inherit: false)
    other = app(group: group)
    membership = GroupMembership.create!(group: g, user: u, role: 'viewer')
    assert Access::AppAccess.allowed?(u, inherited)
    refute Access::AppAccess.allowed?(u, inherited, action: :upload)
    refute Access::AppAccess.allowed?(u, isolated)
    refute Access::AppAccess.allowed?(u, other)
    membership.update!(role: 'developer')
    assert Access::AppAccess.allowed?(u, inherited, action: :upload)
    refute Access::AppAccess.allowed?(u, inherited, action: :manage)
    Collaborator.create!(user: u, app: isolated, role: 'admin', owner: false)
    assert Access::AppAccess.allowed?(u, isolated, action: :manage)
    membership.destroy!
    refute Access::AppAccess.allowed?(u, inherited)
    assert Access::AppAccess.allowed?(u, isolated)
    assert_empty Access::AppAccess.scope(nil)
  end

  def test_global_developer_is_not_a_platform_administrator
    a = app
    developer = user('developer')
    refute Access::AppAccess.allowed?(developer, a)
    assert Access::AppAccess.allowed?(user('admin'), a, action: :manage)
    assert_raises(KeyError) { Access::AppAccess.scope(developer, action: :misspelled_permission) }
  end

  def test_storage_inheritance_and_immutable_object_location
    g = group
    a = app(group: g)
    first = profile
    second = profile
    g.update!(storage_profile: first)
    assert_equal first, a.effective_storage_profile
    a.update!(storage_profile: second)
    assert_equal second, a.effective_storage_profile
    object = StoredObject.create!(app: a, storage_profile: first, key: 'objects/one', filename: 'one.apk', kind: 'package')
    refute first.update(bucket: 'changed-bucket')
    assert_equal first, object.reload.storage_profile
    refute object.update(storage_profile: second)
    first.reload.update!(enabled: false)
    assert_equal second, a.reload.effective_storage_profile
    a.update!(storage_profile: nil)
    assert_raises(ArgumentError) { a.reload.effective_storage_profile }
  end

  def test_credentials_are_encrypted_and_rotation_preserves_location
    p = profile
    p.credentials = { access_key_id: 'example-access', secret_access_key: 'example-private-secret' }
    p.save!
    refute_includes p.reload.credentials_ciphertext, 'example-private-secret'
    refute_includes p.as_json.to_s, 'example-private-secret'
    refute_includes p.as_json.to_s, 'credentials_ciphertext'
    assert_equal 'example-private-secret', p.credentials.fetch('secret_access_key')
    previous = p.credentials_version
    p.credentials = { access_key_id: 'new-access', secret_access_key: 'new-secret' }
    p.save!
    assert_equal previous + 1, p.credentials_version
    assert_equal 'private-test', p.bucket
    refute p.update(endpoint: 'https://example.com/path?secret=foo')
  end

  def test_group_revocation_changes_ticket_version
    u = user
    g = group
    a = app(group: g)
    before = Access::AppAccess.version(a)
    membership = GroupMembership.create!(user: u, group: g, role: 'viewer')
    after = Access::AppAccess.version(a.reload)
    refute_equal before, after
    membership.destroy!
    refute_equal after, Access::AppAccess.version(a.reload)
  end

  def test_direct_grant_revocation_changes_ticket_version
    u = user
    a = app
    before = Access::AppAccess.version(a)
    membership = Collaborator.create!(user: u, app: a, role: 'member', owner: false)
    after = Access::AppAccess.version(a.reload)
    refute_equal before, after
    membership.destroy!
    refute_equal after, Access::AppAccess.version(a.reload)
  end

  def test_storage_selection_requires_explicit_grant
    a = app(group: group)
    other = app(group: group)
    p = profile
    refute p.available_for?(a)
    StorageGrant.create!(storage_profile: p, group: a.group)
    assert p.available_for?(a)
    refute p.available_for?(other)
    refute p.available_for?(App.new(name: "Unsaved", group: other.group))
    assert_raises(ActiveRecord::RecordInvalid) { StorageGrant.create!(storage_profile: p, group: a.group, app: a) }
  end
end
