# UI acceptance

Use a disposable database, never the deployed database. `fixtures.rb` checks the test database hostname before creating data. It creates an admin-visible catalog with long English/Chinese names, populated channels, empty states and an archived app. Application package files are placeholders: these fixtures cover UI rendering and navigation, not actual package upload or installation.

1. Start the existing runtime image with current `app/`, `config/`, `db/` and `lib/` sources, an isolated PostgreSQL instance, and `test/s3/test.env`.
2. Build assets with `npm run build` and `npm run build:css`. Copy the built files, run `SKIP_JS_BUILD=1 SKIP_CSS_BUILD=1 bundle exec rails assets:precompile`, then `bundle exec rails db:prepare` in the test runtime. Serve Rails on port 3001, bound to `127.0.0.1:18912` on the host.
3. Run `bundle exec rails runner test/ui/fixtures.rb` in the runtime, then copy `/tmp/ui-fixture.json` to the host as `/tmp/zealot-ui-fixture.json`.
4. With Playwright available and Google Chrome installed, run `node test/ui/theme.cjs`. Set `NODE_PATH` to the Playwright installation when it is not installed in the project.

Optional environment values: `ZEALOT_UI_URL`, `ZEALOT_UI_FIXTURE`, `ZEALOT_UI_OUTPUT`, `ZEALOT_UI_EMAIL`, `ZEALOT_UI_PASSWORD`. Default credentials are the disposable test account from `test/s3/test.env`. Results and screenshots go to ignored `tmp/ui-review/` by default.

The acceptance script covers 24 representative page/theme/viewport combinations and 20 secondary-page combinations, semantic token contrast, appearance persistence and live system mode, active/archived search and sort, no-results recovery, Turbo create-app modal, channel pagination, upload-page navigation, empty channels, keyboard skip navigation, desktop sidebar toggling, mobile sidebar navigation and Escape/overlay dismissal after Turbo navigation. It also fails on browser JavaScript errors or same-origin HTTP failures. Screenshots still require visual inspection.

`unified_install.cjs` uses a separate fixture JSON with `app`, `scheme`, `code`, `path`, `android`, `ios`, `android_id` and `ios_id`. Set the scheme to `public` and leave its channels private to check independent entry access. Device redirects must stay under `/install_links/<path>/channels/<id>`.
