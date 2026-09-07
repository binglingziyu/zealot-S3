require 'minitest/autorun'
require 'tmpdir'
require 'zip'
raise 'Test environment required' unless ENV['ZEALOT_S3_BUCKET']&.start_with?('zealot-test-')
raise 'File mode required' unless ENV.fetch('ZEALOT_STORAGE') == 'file'

class LocalStorageRegressionTest < Minitest::Test
  def test_local_upload_download_and_remove
    Dir.mktmpdir do |directory|
      app = App.create!(name: 'Local storage regression')
      user = User.find_by!(email: ENV.fetch('ZEALOT_ADMIN_EMAIL'))
      app.create_owner(user)
      channel = app.schemes.create!(name: 'Local').channels.create!(name: 'Linux', device_type: 'linux')
      path = File.join(directory, 'package.zip')
      Zip::File.open(path, create: true) { |zip| zip.get_output_stream('readme') { |f| f.write('local regression') } }
      session = ActionDispatch::Integration::Session.new(Rails.application)
      session.host! ENV.fetch('ZEALOT_DOMAIN')
      session.https!
      session.post('/api/apps/upload', params: { token: user.token, channel_key: channel.key, file: Rack::Test::UploadedFile.new(path) })
      assert_equal 201, session.response.status
      release = channel.releases.first!
      refute release.file.remote_storage?
      assert release.file?
      assert_equal File.size(path), release.size
      stored_path = release.file.path
      assert File.file?(stored_path)
      session.get(release.download_url)
      session.follow_redirect!
      assert_equal 200, session.response.status
      assert_equal File.binread(path), session.response.body
      app.destroy!
      refute File.exist?(stored_path)
    ensure
      app&.destroy! if app&.persisted?
    end
  end
end
