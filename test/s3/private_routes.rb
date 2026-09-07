require 'minitest/autorun'
require 'tmpdir'
require 'zip'
raise 'Disposable bucket required' unless ENV.fetch('ZEALOT_S3_BUCKET').start_with?('zealot-test-')

class PrivateRoutesTest < Minitest::Test
  def setup
    @tag = SecureRandom.hex(6)
    @owner = User.find_by!(email: ENV.fetch('ZEALOT_ADMIN_EMAIL'))
    @outsider = User.create!(username: "outsider-#{@tag}", email: "outsider-#{@tag}@test.invalid", password: SecureRandom.hex(20), confirmed_at: Time.current)
    @group = Group.create!(name: "Private #{@tag}")
    @app = App.create!(name: "Private app #{@tag}", group: @group)
    @app.create_owner(@owner)
    @channel = @app.schemes.create!(name: 'Private').channels.create!(name: 'Linux', device_type: 'linux', bundle_id: '*')
    @session = ActionDispatch::Integration::Session.new(Rails.application)
    @session.host!(ENV.fetch('ZEALOT_DOMAIN'))
    @session.https!
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'test.zip')
      Zip::File.open(path, create: true) { |z| z.get_output_stream('readme') { |f| f.write('private package') } }
      @session.post('/api/apps/upload', params: { token: @owner.token, channel_key: @channel.key, file: Rack::Test::UploadedFile.new(path) })
      assert_equal 201, @session.response.status
      @release = @channel.releases.first!
    end
  end

  def teardown
    @app&.destroy!
    @group&.destroy!
    @outsider&.destroy!
  end

  def test_api_list_and_guessable_resources_are_private
    @session.get('/api/apps', params: { token: @outsider.token })
    assert_equal 200, @session.response.status
    refute_includes @session.response.body, @app.name
    @session.get("/api/apps/#{@app.id}", params: { token: @outsider.token })
    assert_equal 403, @session.response.status
    @session.get("/api/channels/#{@channel.id}", params: { token: @outsider.token })
    assert_equal 403, @session.response.status
    @session.get(@release.download_url)
    refute_includes @session.response.headers['Location'].to_s, 'X-Amz-Signature'
    @session.get("/download/releases/#{@release.id}/#{@release.download_filename}")
    refute_includes @session.response.headers['Location'].to_s, 'X-Amz-Signature'
    GroupMembership.create!(user: @outsider, group: @group, role: 'viewer')
    @session.get('/api/apps', params: { token: @outsider.token })
    assert_equal 200, @session.response.status
    assert_includes @session.response.body, @app.name
    @session.get("/api/apps/#{@app.id}", params: { token: @outsider.token })
    assert_equal 200, @session.response.status
  end

  def test_group_viewer_cannot_upload_or_manage
    membership = GroupMembership.create!(user: @outsider, group: @group, role: 'viewer')
    refute ReleasePolicy.new(@outsider, @release).create?
    refute ChannelPolicy.new(@outsider, @channel).update?
    membership.update!(role: 'developer')
    assert ReleasePolicy.new(@outsider, @release).create?
    refute ChannelPolicy.new(@outsider, @channel).update?
    membership.update!(role: 'admin')
    assert ChannelPolicy.new(@outsider, @channel).update?
  end
end
