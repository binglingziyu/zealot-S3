# Browser and Fastlane integration checks

Use only the disposable PostgreSQL/MinIO environment described in `docs/implementation-progress.md` and `test/s3/test.env`. Production credentials are not needed. These tests create retained test objects and releases; dispose of the test database and bucket together after the complete recovery rehearsal.

The test Rails server listens on container port 3001 with `ZEALOT_ALLOW_HTTP_STORAGE=true` and `RAILS_SERVE_STATIC_FILES=1`. Build the current JS/CSS and Rails assets, including the Font Awesome font directory, before starting it. Wait for an HTTP response before running browser tests.

For Docker Desktop, run two containers using `proxy.rb`, the existing test image and network. Mount the script read-only, set `LISTEN_PORT`, `TARGET_HOST`, `TARGET_PORT`, and invoke `ruby /proxy.rb` as the entrypoint command:

| Published binding | Listen port | Target host | Target port |
| --- | --- | --- | --- |
| `127.0.0.1:18902:3001` | 3001 | zealot-next-runner | 3001 |
| `127.0.0.1:18903:9000` | 9000 | zealot-next-store | 9000 |

Initialize fixtures and copy the public fixture identifiers to the browser host:

```sh
docker exec -e ZEALOT_ALLOW_HTTP_STORAGE=true zealot-next-runner bundle exec rails runner test/s3/browser/setup.rb
docker cp zealot-next-runner:/tmp/browser-fixture.json /tmp/zealot-browser-fixture.json
npm install --prefix /tmp/zealot-browser-test playwright@1.55.0 --no-audit --no-fund
NODE_PATH=/tmp/zealot-browser-test/node_modules node test/s3/browser/direct.cjs
NODE_PATH=/tmp/zealot-browser-test/node_modules node test/s3/browser/resume.cjs
NODE_PATH=/tmp/zealot-browser-test/node_modules node test/s3/browser/cancel.cjs
```

The scripts use installed Google Chrome in a separate headless context. `direct.cjs` uploads real APK/IPA/dSYM files, waits for publication, captures screenshots and records request sizes without logging signed URL queries. It fails if package bodies go to the application origin. `resume.cjs` disconnects part 2 three times, then resumes and verifies part 1 is not retransmitted.

`cancel.cjs` holds an active storage PUT, clicks the browser cancellation button, and verifies the authenticated server response reports a cancelled session with no published release.

For the actual Fastlane action, install Fastlane in an isolated gem directory; using the image's existing compiled gems avoids requiring native build tools:

```sh
docker exec -w /tmp -e GEM_HOME=/tmp/fastlane-gems -e GEM_PATH=/tmp/fastlane-gems:/app/vendor/bundle/ruby/3.4.0:/usr/local/lib/ruby/gems/3.4.0 zealot-next-runner gem install fastlane -v 2.228.0 --conservative --no-document
docker cp clients/. zealot-next-runner:/app/clients/
docker exec -w /tmp -e GEM_HOME=/tmp/fastlane-gems -e GEM_PATH=/tmp/fastlane-gems:/app/vendor/bundle/ruby/3.4.0:/usr/local/lib/ruby/gems/3.4.0 zealot-next-runner ruby -I/app/clients/fastlane/lib /app/test/s3/browser/fastlane_action.rb
```

The token-bearing Fastlane fixture stays in the test container with mode 0600. The action test validates configuration defaults, publication, and legacy lane output values. Its storage endpoint is internal to the Docker network; the browser fixture uses the public test bridge instead.

Manual real-browser parse-retry acceptance uses a fresh Android fixture channel. Set its bundle constraint to `invalid.retry.fixture`, upload `fixtures/android.apk`, and wait for the mismatch error and visible “重试解析” button. Confirm the session is failed with no release, then correct the channel constraint to `*` and click that retry button without submitting the file again. Confirm navigation to the published release, one release total, two parse attempts, unchanged stored object ID/ETag/SHA256, and no repeated parts-signing request. This was completed against current code on 2026-09-07; exact evidence is in `docs/implementation-progress.md`.
