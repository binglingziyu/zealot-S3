require_relative 'multipart'

class ServiceAccountsTest < MultipartTest
  def test_service_account_is_scoped_noninteractive_rotatable_and_revocable
    other = App.create!(name: "Other #{@tag}", storage_profile: @profile)
    @extra_apps << other
    group = Group.create!(name: "Service group #{@tag}")
    other.update!(group: group)
    account = Access::ServiceAccounts.create!(actor: @user, name: "CI #{@tag}", role: 'read', app_ids: [@app.id])
    @extra_users << account
    refute account.active_for_authentication?
    assert account.api_access_active?
    assert Access::AppAccess.allowed?(account, @app, action: :view)
    refute Access::AppAccess.allowed?(account, @app, action: :upload)
    refute Access::AppAccess.allowed?(account, @app, action: :manage)
    GroupMembership.create!(user: account, group: group, role: 'admin')
    refute Access::AppAccess.allowed?(account, other, action: :view)

    browser = ActionDispatch::Integration::Session.new(Rails.application)
    browser.host! ENV.fetch('ZEALOT_DOMAIN')
    browser.https!
    headers = { 'Authorization' => "Bearer #{account.token}" }
    browser.get('/api/apps', headers: headers)
    assert_equal 200, browser.response.status
    assert_includes browser.response.body, @app.name
    refute_includes browser.response.body, other.name
    browser.post('/api/upload_sessions', params: { channel_key: @channel.key, filename: 'test.bin', byte_size: 4, idempotency_key: @tag }, headers: headers)
    assert_equal 403, browser.response.status
    Access::ServiceAccounts.grant!(actor: @user, account: account, role: 'upload', app_ids: [@app.id])
    assert Access::AppAccess.allowed?(account.reload, @app, action: :upload)
    browser.post('/api/upload_sessions', params: { channel_key: @channel.key, filename: 'test.bin', byte_size: 4, idempotency_key: @tag }, headers: headers)
    assert_equal 201, browser.response.status
    session = UploadSession.find(JSON.parse(browser.response.body).fetch('id'))
    stale = User.find(account.id)
    original_version = @app.reload.access_version
    Access::ServiceAccounts.rotate!(actor: @user, account: account)
    assert_operator @app.reload.access_version, :>, original_version
    browser.get('/api/apps', headers: headers)
    refute_equal 200, browser.response.status
    fresh = { 'Authorization' => "Bearer #{account.token}" }
    browser.get('/api/apps', headers: fresh)
    assert_equal 200, browser.response.status
    Access::ServiceAccounts.revoke!(actor: @user, account: account)
    refute Access::AppAccess.allowed?(account.reload, @app, action: :view)
    refute Access::AppAccess.allowed?(stale, @app, action: :upload)
    refute session.upload_allowed?
    browser.get('/api/apps', headers: fresh)
    refute_equal 200, browser.response.status
  ensure
    other&.update!(group: nil)
    group&.destroy!
  end
end
