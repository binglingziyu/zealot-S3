Gem::Specification.new do |spec|
  spec.name = 'fastlane-plugin-zealot_direct'
  spec.version = '0.1.0'
  spec.summary = 'Direct multipart uploads to Zealot S3 storage'
  spec.authors = ['Zealot S3 contributors']
  spec.license = 'MIT'
  spec.homepage = 'https://github.com/binglingziyu/zealot-S3'
  spec.files = Dir['lib/**/*.rb']
  spec.require_paths = ['lib']
  spec.required_ruby_version = '>= 2.7'
  spec.add_dependency 'fastlane', '>= 2.200'
end
