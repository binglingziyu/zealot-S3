require_relative 'multipart'

class LegacyParseAccessTest < MultipartTest
  def test_revoked_legacy_jobs_stop_before_downloading
    actor = User.create!(username: "Former uploader #{@tag}", email: "former-#{@tag}@test.invalid", password: SecureRandom.hex(20), confirmed_at: Time.current)
    @extra_users << actor
    grant = Collaborator.create!(user: actor, app: @app, role: :developer)
    release = @channel.releases.new
    release[:file] = 'never-download.zip'
    release.save!(validate: false)
    debug = DebugFile.new(app: @app, device_type: 'ios')
    file_accessed = false
    debug.define_singleton_method(:file) { file_accessed = true; raise 'Must not download' }
    grant.destroy!
    assert_raises(Pundit::NotAuthorizedError) { TeardownJob.new.perform(release.id, actor.id) }
    assert_raises(Pundit::NotAuthorizedError) { DebugFileTeardownJob.new.perform(debug, actor.id) }
    refute file_accessed
  end

  def test_guest_mode_does_not_allow_anonymous_standalone_parse
    previous = Setting.guest_mode
    Setting.guest_mode = true
    browser = ActionDispatch::Integration::Session.new(Rails.application)
    browser.host! ENV.fetch('ZEALOT_DOMAIN')
    browser.https!
    browser.get('/users/sign_in')
    token = Nokogiri::HTML(browser.response.body).at_css('meta[name="csrf-token"]')['content']
    browser.post('/teardowns', params: { authenticity_token: token })
    assert_equal 302, browser.response.status
    assert_includes browser.response.headers.fetch('Location'), '/users/sign_in'
  ensure
    Setting.guest_mode = previous
  end
end
