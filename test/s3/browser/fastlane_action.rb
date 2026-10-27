require 'fastlane'
require 'fastlane/plugin/zealot_direct'
require 'json'
values = JSON.parse(File.read('/tmp/fastlane-fixture.json'), symbolize_names: true)
action = Fastlane::Actions::ZealotDirectUploadAction
params = FastlaneCore::Configuration.create(action.available_options, values)
result = action.run(params)
raise 'Expected ready' unless result['state'] == 'ready'
raise 'Missing lane release' unless Fastlane::Actions.lane_context[:ZEALOT_RELEASE_ID] == result['release_id']
raise 'Missing lane app' unless Fastlane::Actions.lane_context[:ZEALOT_APP_ID] == result['app_id']
raise 'Missing QR URL' unless Fastlane::Actions.lane_context[:ZEALOT_QRCODE_URL].to_s.include?('qrcode')
raise 'Missing installation URL' if Fastlane::Actions.lane_context[:ZEALOT_INSTALL_URL].to_s.empty?
raise 'Unexpected error' if Fastlane::Actions.lane_context[:ZEAALOT_ERROR_MESSAGE]
puts "Fastlane action passed; release #{result['release_id']}"
