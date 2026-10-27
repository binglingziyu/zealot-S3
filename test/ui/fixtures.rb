raise 'Disposable UI database required' unless ENV['ZEALOT_POSTGRES_HOST'] == 'zealot-s3-test-db'
user = User.find_by!(email: 's3-test@zealot.test')
Setting.site_domain = '127.0.0.1:18912'
Setting.per_page = 5
names = ['Orbit Mobile', 'Atlas Console', 'Zealot Developer Tools', '智能物流调度平台', 'Release-Platform-With-A-Very-Long-Application-Name-For-Layout', 'Empty Application']
channels = []
names.each_with_index do |name, i|
  app = App.find_or_create_by!(name: name)
  app.create_owner(user) unless app.collaborators.exists?(user: user)
  scheme = app.schemes.find_or_create_by!(name: 'Production')
  channel = scheme.channels.find_or_create_by!(name: 'Android') { |c| c.device_type = 'android'; c.bundle_id = '*'; c.git_url = 'https://git.example.com/engineering/mobile-release-platform' }
  channels << channel
  next if i == names.length - 1 || channel.releases.exists?
  8.times do |n|
    Release.insert_all!([{channel_id: channel.id, version: n + 1, name: name, release_version: "2.#{n / 3}.#{n}", build_version: (100 + n).to_s, file: 'fixture.apk', device_type: 'Android', release_type: 'debug', source: 'web', branch: 'release/production', git_commit: 'a7f203e6e86e36c', changelog: [{'message' => '优化应用启动速度，改善发布与安装体验。'}, {'message' => 'Improve stability and fix known issues.'}], created_at: n.hours.ago, updated_at: n.hours.ago}])
  end
end
archive = App.find_or_create_by!(name: 'Archived Demo') { |app| app.archived = true }
archive.create_owner(user) unless archive.collaborators.exists?(user: user)
helpers = Rails.application.routes.url_helpers
File.write('/tmp/ui-fixture.json', JSON.generate({channel: helpers.friendly_channel_overview_path(channels.first), empty_channel: helpers.friendly_channel_overview_path(channels.last), app_id: channels.first.app.id, archived: helpers.archived_apps_path}))
puts 'UI fixtures ready'
