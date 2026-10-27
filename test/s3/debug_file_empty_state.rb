require 'minitest/autorun'
require 'warden/test/helpers'
require 'nokogiri'

raise 'Disposable database required' unless ActiveRecord::Base.connection_db_config.configuration_hash[:host] == 'zealot-s3-test-db'

class DebugFileEmptyStateTest < Minitest::Test
  include Warden::Test::Helpers

  def setup
    Warden.test_mode!
    ActiveRecord::Base.connection.begin_transaction(joinable: false)
    tag = SecureRandom.hex(6)
    @user = User.create!(username: "debug-#{tag}", email: "debug-#{tag}@test.invalid",
                         password: SecureRandom.hex(20), confirmed_at: Time.current, role: :member)
    @group = Group.create!(name: "Debug #{tag}")
    GroupMembership.create!(group: @group, user: @user, role: :admin)
    @session = ActionDispatch::Integration::Session.new(Rails.application)
    @session.host!(ENV.fetch('ZEALOT_DOMAIN'))
    @session.https!
    login_as(@user, scope: :user)
  end

  def teardown
    Warden.test_reset!
    ActiveRecord::Base.connection.rollback_transaction
  end

  def check_empty_state(can_upload:)
    @session.get('/debug_files')
    assert_equal 200, @session.response.status
    html = Nokogiri::HTML(@session.response.body)
    assert_equal can_upload, html.css('a[href="/debug_files/new"]').any?
    assert_equal !can_upload, @session.response.body.include?(I18n.t('debug_files.index.not_found.no_upload_target'))
    assert_equal can_upload, @session.response.body.include?(I18n.t('debug_files.index.not_found.body_html'))
  end

  def test_group_admin_without_apps_sees_actionable_message
    check_empty_state(can_upload: false)
  end

  def test_group_admin_with_active_app_sees_upload_button
    App.create!(name: 'Upload target', group: @group, inherit_group_permissions: true)
    check_empty_state(can_upload: true)
  end

  def test_archived_app_is_not_an_upload_target
    App.create!(name: 'Archived target', group: @group, archived: true, inherit_group_permissions: true)
    check_empty_state(can_upload: false)
  end

  def test_view_only_app_is_not_an_upload_target
    @user.group_memberships.first.update!(role: :viewer)
    App.create!(name: 'View target', group: @group, inherit_group_permissions: true)
    check_empty_state(can_upload: false)
  end
end
