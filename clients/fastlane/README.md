# Zealot direct upload plugin

Requires the direct-upload Zealot fork, Ruby 2.7+, and Fastlane. This plugin uploads package bytes directly to the storage endpoint. Zealot receives control requests, downloads the completed object for verification and analysis, and publishes the release afterward.

Add the plugin from a checkout of this repository to your Fastlane `Pluginfile`:

```ruby
gem 'fastlane-plugin-zealot_direct', path: '../zealot-S3/clients/fastlane'
```

Run `bundle install`, then use:

```ruby
lane :distribute do
  gradle(task: 'assembleRelease') # or build_app for iOS
  result = zealot_direct_upload(
    endpoint: ENV.fetch('ZEALOT_ENDPOINT'),
    token: ENV.fetch('ZEALOT_TOKEN'),
    channel_key: ENV.fetch('ZEALOT_CHANNEL_KEY'),
    changelog: 'Release notes'
  )
  UI.message(result.fetch('release_url'))
end
```

Use a dedicated CI user with upload permission only on the intended applications. Keep its token in the CI secret store. No R2/S3 credentials are needed by Fastlane.

`file:` overrides the IPA/APK path from the preceding build action. For debug symbols, pass `kind: 'debug'`, `file: 'symbols.zip'`, `release_version:` and `build_version:`. The result then contains `debug_file_id` instead of `release_id`.

The default idempotency key derives from channel, kind, filename and SHA256. Rerunning the same upload resumes completed parts or returns the already published release. Supply a stable `idempotency_key:` per CI artifact when desired; use a new key to deliberately publish the same artifact again. A key cannot be reused for different bytes. Each missing part gets up to three attempts with fresh signatures. Analysis failure fails the lane; repair the cause and retry analysis through Zealot before rerunning the same upload.

`timeout:` defaults to 600 seconds per request; `wait_timeout:` defaults to 1800 seconds for analysis. A wait timeout leaves the server job running. Rerunning with the same key resumes waiting. `verify_ssl: false` affects only the Zealot origin; object-storage TLS remains verified.

The action returns the session result and sets the existing Zealot lane values `ZEALOT_APP_ID`, `ZEALOT_RELEASE_ID`, `ZEALOT_RELEASE_URL`, `ZEALOT_QRCODE_URL`, `ZEALOT_INSTALL_URL`, and the upstream error variable `ZEAALOT_ERROR_MESSAGE`. It also sets the release/install URL environment variables. The original `zealot` action remains an upload through the application server; use `zealot_direct_upload` to bypass that path.

Browser uploads use the same protocol through authenticated, CSRF-protected web endpoints. Configure storage CORS to allow your exact Zealot origin and PUT requests. Presigned links are temporary credentials; do not log or share them.
