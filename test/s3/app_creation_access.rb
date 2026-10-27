require 'minitest/autorun'
require 'warden/test/helpers'
require 'nokogiri'

raise 'Disposable database required' unless ActiveRecord::Base.connection_db_config.configuration_hash[:host] == 'zealot-s3-test-db'

class AppCreationAccessTest < Minitest::Test
  include Warden::Test::Helpers

  def setup
    Warden.test_mode!
    ActiveRecord::Base.connection.begin_transaction(joinable: false)
    tag = SecureRandom.hex(6)
    @user = User.create!(username: "creator-#{tag}", email: "creator-#{tag}@test.invalid",
                         password: SecureRandom.hex(20), confirmed_at: Time.current, role: :member)
    @managed = Group.create!(name: "Managed #{tag}")
    @other = Group.create!(name: "Other #{tag}")
    @session = ActionDispatch::Integration::Session.new(Rails.application)
    @session.host!(ENV.fetch('ZEALOT_DOMAIN'))
    @session.https!
    login_as(@user, scope: :user)
  end

  def teardown
    Warden.test_reset!
    ActiveRecord::Base.connection.rollback_transaction
  end

  def grant(role = 'admin', group = @managed)
    GroupMembership.create!(group: group, user: @user, role: role)
  end

  def submit(group_id)
    @session.get('/apps')
    assert_equal 200, @session.response.status
    token = Nokogiri::HTML(@session.response.body).at_css('meta[name="csrf-token"]')['content']
    @session.post('/apps', params: { authenticity_token: token,
      app: { name: 'Permission regression app', group_id: group_id } })
  end

  def test_group_admin_can_open_modal_and_choose_only_managed_groups
    grant
    second = Group.create!(name: "Second #{@managed.id}")
    grant('admin', second)
    grant('viewer', @other)
    @session.get('/apps/new', headers: { 'Turbo-Frame' => 'modal' })
    assert_equal 200, @session.response.status, @session.response.body[0, 500]
    form = Nokogiri::HTML(@session.response.body)
    options = form.css('select[name="app[group_id]"] option').reject { |option| option['value'].blank? }
    assert_equal [@managed.id, second.id].sort, options.map { |option| option['value'].to_i }.sort
    assert_equal @managed.id.to_s, form.at_css('select[name="app[group_id]"] option[selected]')['value']
    assert form.at_css('turbo-frame#modal form')
  end

  def test_group_admin_can_create_in_managed_group
    grant
    submit(@managed.id)
    assert_equal 302, @session.response.status, @session.response.body[0, 500]
    app = App.find_by!(name: 'Permission regression app')
    assert_equal @managed.id, app.group_id
    assert app.collaborators.exists?(user: @user, owner: true, role: 'admin')
  end

  def test_group_admin_cannot_create_in_other_group_or_without_group
    grant
    grant('developer', @other)
    [@other.id, ''].each do |group_id|
      assert_no_creation(group_id)
    end
  end

  def test_viewer_developer_and_app_admin_cannot_create_apps
    membership = grant('viewer')
    %w[viewer developer].each do |role|
      membership.update!(role: role)
      @session.get('/apps/new')
      assert_equal 403, @session.response.status
      assert_no_creation(@managed.id)
    end
    membership.destroy!
    app = App.create!(name: 'Existing app', group: @managed)
    Collaborator.create!(app: app, user: @user, role: :admin, owner: true)
    @session.get('/apps/new')
    assert_equal 403, @session.response.status
    assert_no_creation(@managed.id)
  end

  def test_platform_admin_can_create_without_group
    @user.update!(role: :admin)
    @session.get('/apps/new')
    assert_equal 200, @session.response.status
    submit('')
    assert_equal 302, @session.response.status
    assert_nil App.find_by!(name: 'Permission regression app').group_id
  end

  private

  def assert_no_creation(group_id)
    count = App.count
    submit(group_id)
    assert_equal 403, @session.response.status
    assert_equal count, App.count
  end
end
