require_relative 'multipart'
require 'minitest/mock'
raise 'External job mode required' unless GoodJob.configuration.execution_mode == :external

class DeliveryTest < MultipartTest
  def setup
    super
    @hook = WebHook.create!(channel_id: @channel.id, url: 'https://unused.invalid/secret', upload_events: 1, download_events: 1)
    @hook.channels << @channel
    @previous_recovery = ENV['ZEALOT_RECOVERY_MODE']
  end

  def teardown
    @previous_recovery.nil? ? ENV.delete('ZEALOT_RECOVERY_MODE') : ENV['ZEALOT_RECOVERY_MODE'] = @previous_recovery
    WebHookDelivery.where(web_hook: @hook).delete_all
    @hook.destroy!
    super
  end

  def publish
    bytes = 'notification package'
    session = initiate(bytes)
    session.update!(metadata: { release_version: '1.0', build_version: '1' })
    service = Uploads::Multipart.new(session, actor: @user)
    assert_equal '200', put(service.sign_parts([1]).first, bytes).code
    service.complete
    ProcessUploadJob.perform_now(session.id)
    assert_equal 'ready', session.reload.state, session.error_message
    session.release
  end

  def test_delivery_publication_is_atomic_fixed_to_release_and_sent_once
    release = publish
    scope = WebHookDelivery.where(web_hook: @hook)
    assert_equal 1, scope.count
    @channel.perform_web_hook('upload_events', @user.id, release: release)
    assert_equal 1, scope.count
    Release.transaction do
      @channel.perform_web_hook('download_events', @user.id, release: release)
      raise ActiveRecord::Rollback
    end
    assert_equal 1, scope.count
    newer = release.dup
    newer.release_version = '2.0'
    newer.save!
    @channel.perform_web_hook('download_events', @user.id, release: release)
    delivery = scope.find_by!(event_name: 'download_events')
    requests = []
    sender = lambda do |url, body, headers, &block|
      requests << [JSON.parse(body), headers]
      Struct.new(:status).new(204)
    end
    Faraday.stub(:post, sender) do
      WebHookDeliveryJob.perform_now(delivery.id)
      WebHookDeliveryJob.perform_now(delivery.id)
    end
    assert_equal 'sent', delivery.reload.state
    assert_equal 1, requests.size
    assert_equal '1.0', requests.first[0]['release_version']
    assert_equal delivery.id, requests.first[1]['Idempotency-Key']
    assert_equal 1, delivery.attempts
  end

  def test_delivery_uncertainty_manual_retry_csrf_revocation_and_restore
    release = publish
    delivery = WebHookDelivery.find_by!(web_hook: @hook)
    Faraday.stub(:post, ->(*) { raise Faraday::TimeoutError, 'secret response details' }) do
      WebHookDeliveryJob.perform_now(delivery.id)
    end
    assert_equal 'uncertain', delivery.reload.state
    assert_equal 'Faraday::TimeoutError', delivery.error_class
    Faraday.stub(:post, ->(*) { flunk 'Uncertain delivery was automatically resent' }) { WebHookDeliveryJob.perform_now(delivery.id) }
    assert_equal 1, delivery.reload.attempts

    Warden.test_mode!
    login_as(@user, scope: :user)
    browser = ActionDispatch::Integration::Session.new(Rails.application)
    browser.host! ENV.fetch('ZEALOT_DOMAIN')
    browser.https!
    routes = Rails.application.routes.url_helpers
    browser.get(routes.deliveries_channel_web_hook_path(@channel, @hook))
    assert_equal 200, browser.response.status
    token = Nokogiri::HTML(browser.response.body).at_css('meta[name="csrf-token"]')['content']
    retry_url = routes.retry_delivery_channel_web_hook_path(@channel, @hook, delivery_id: delivery.id)
    browser.post(retry_url)
    assert_equal 422, browser.response.status
    browser.post(retry_url, headers: { 'X-CSRF-Token' => token })
    assert_equal 303, browser.response.status
    assert_equal 'pending', delivery.reload.state

    guest = User.create!(username: "delivery-#{@tag}", email: "delivery-#{@tag}@test.invalid", password: SecureRandom.hex(20), confirmed_at: Time.current)
    @extra_users << guest
    grant = Collaborator.create!(app: @app, user: guest, role: :developer)
    revoked = WebHookDelivery.enqueue(event: 'download_events', web_hook: @hook, release: release, user: guest, key: "revoked-#{@tag}")
    grant.destroy!
    Faraday.stub(:post, ->(*) { flunk 'Revoked user emitted a webhook' }) { WebHookDeliveryJob.perform_now(revoked.id) }
    assert_equal 'skipped', revoked.reload.state

    ENV['ZEALOT_RECOVERY_MODE'] = 'true'
    WebHookDelivery.suppress_before!(Time.current)
    Faraday.stub(:post, ->(*) { flunk 'Recovery emitted a webhook' }) { WebHookDeliveryJob.perform_now(delivery.id) }
    assert_equal 'skipped', delivery.reload.state
    assert_equal 'RecoverySuppressed', delivery.error_class
  end
end
