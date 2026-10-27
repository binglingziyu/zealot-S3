require 'minitest/autorun'
require 'warden/test/helpers'
require 'nokogiri'
raise 'Disposable bucket required' unless ENV.fetch('ZEALOT_S3_BUCKET').start_with?('zealot-test-')

class WebhookAccessTest < Minitest::Test
  include Warden::Test::Helpers

  def setup
    Warden.test_mode!
    tag = SecureRandom.hex(6)
    @user = User.create!(username: "hook-#{tag}", email: "hook-#{tag}@test.invalid", password: SecureRandom.hex(20), confirmed_at: Time.current)
    @group = Group.create!(name: "Hooks #{tag}")
    GroupMembership.create!(group: @group, user: @user, role: 'admin')
    @own = App.create!(name: "Own #{tag}", group: @group)
    @other = App.create!(name: "Private #{tag}")
    @channel = @own.schemes.create!(name: 'Own').channels.create!(name: 'Own', device_type: 'ios')
    @private_channel = @other.schemes.create!(name: 'Secret').channels.create!(name: 'Secret', device_type: 'ios')
    @hook = WebHook.create!(channel_id: @private_channel.id, url: 'https://private.invalid/secret-destination', body: '{}')
    @hook.channels << @private_channel
    @browser = ActionDispatch::Integration::Session.new(Rails.application)
    @browser.host! ENV.fetch('ZEALOT_DOMAIN')
    @browser.https!
    login_as(@user, scope: :user)
    @routes = Rails.application.routes.url_helpers
  end

  def teardown
    Warden.test_reset!
    WebHook.where(channel_id: [@channel.id, @private_channel.id]).destroy_all
    @own.destroy!
    @other.destroy!
    @group.destroy!
    @user.destroy!
  end

  def csrf
    @browser.get(@routes.channel_path(@channel))
    assert_equal 200, @browser.response.status
    Nokogiri::HTML(@browser.response.body).at_css('meta[name="csrf-token"]')['content']
  end

  def test_group_admin_sees_only_managed_hooks_and_cannot_access_global_console
    csrf
    refute_includes @browser.response.body, @hook.url
    refute_includes @browser.response.body, @other.name
    @browser.get(@routes.admin_web_hooks_path)
    assert_equal 404, @browser.response.status # admin routes are hidden from non-admins
    refute WebHookPolicy.new(@user, WebHook).index?
    assert_empty Pundit.policy_scope!(@user, WebHook)
  end

  def test_cannot_attach_delete_or_trigger_another_apps_hook
    token = csrf
    headers = { 'X-CSRF-Token' => token }
    @browser.post(@routes.enable_channel_web_hook_path(@channel, @hook), headers: headers)
    assert_equal 404, @browser.response.status
    @browser.delete(@routes.channel_web_hook_path(@private_channel, @hook), headers: headers)
    assert_equal 403, @browser.response.status
    @browser.post(@routes.test_channel_web_hook_path(@channel, @hook, 'upload_events'), headers: headers)
    assert_equal 404, @browser.response.status
    assert_equal [@private_channel.id], @hook.channel_ids
  end

  def test_creation_uses_authorized_route_and_mutations_require_csrf
    token = csrf
    params = { web_hook: { channel_id: @private_channel.id, url: 'https://own.invalid/hook' } }
    @browser.post(@routes.channel_web_hooks_path(@channel), params: params)
    assert_equal 422, @browser.response.status
    @browser.post(@routes.channel_web_hooks_path(@channel), params: params, headers: { 'X-CSRF-Token' => token })
    assert_equal 302, @browser.response.status
    hook = WebHook.find_by!(url: 'https://own.invalid/hook')
    assert_equal @channel.id, hook.channel_id
    assert_equal [@channel.id], hook.channel_ids
    @browser.get(@routes.disable_channel_web_hook_path(@channel, hook))
    assert_equal 404, @browser.response.status
    assert hook.channels.exists?(@channel.id)
  end

  def test_shared_hook_requires_management_of_every_linked_app
    hook = WebHook.create!(channel_id: @channel.id, url: 'https://shared.invalid/hook', body: '{}')
    hook.channels << [@channel, @private_channel]
    refute Pundit.policy!(@user, hook).destroy?
    refute Pundit.policy_scope!(@user, WebHook).exists?(id: hook.id)
    Collaborator.create!(app: @other, user: @user, role: :admin)
    assert Pundit.policy!(@user, hook).destroy?
  end

  def test_app_admin_cannot_execute_a_custom_ruby_template
    token = csrf
    marker = "webhook-execution-#{@user.id}"
    body = "Rails.cache.write(#{marker.inspect}, true); {}"
    @browser.post(@routes.channel_web_hooks_path(@channel), params: { web_hook: { url: 'https://own.invalid/code', body: body } },
      headers: { 'X-CSRF-Token' => token })
    assert_equal 403, @browser.response.status
    assert_nil Rails.cache.read(marker)
    refute WebHook.exists?(url: 'https://own.invalid/code')
  end

  def test_queued_hook_stops_after_revocation_or_during_recovery
    previous = ENV['ZEALOT_RECOVERY_MODE']
    job = AppWebHookJob.new
    observer = self
    job.define_singleton_method(:notificate_failure) { |**| observer.flunk('Unauthorized job emitted a notification') }
    job.define_singleton_method(:send_request) { observer.flunk('Unauthorized job sent a webhook') }
    assert_nil job.perform('upload_events', @hook, @private_channel, @user.id)
    Collaborator.create!(app: @other, user: @user, role: :admin)
    ENV['ZEALOT_RECOVERY_MODE'] = 'true'
    assert_nil job.perform('upload_events', @hook, @private_channel, @user.id)
  ensure
    previous.nil? ? ENV.delete('ZEALOT_RECOVERY_MODE') : ENV['ZEALOT_RECOVERY_MODE'] = previous
  end

  def test_standard_payload_uses_supplied_fields_without_a_release_instance
    rendered = ApplicationController.render(inline: AppWebHookJob.new.send(:default_body), type: :jb,
      assigns: { ci_url: 'https://ci.invalid/build/1', branch: 'main', source: 'fastlane', release_type: 'adhoc' })
    value = JSON.parse(rendered)
    assert_equal 'https://ci.invalid/build/1', value['ci_url']
    assert_equal 'main', value['branch']
    assert_equal 'fastlane', value['source']
    assert_equal 'adhoc', value['release_type']
  end
end
