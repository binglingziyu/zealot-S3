# S3 integration tests

Run `./test/s3/run.sh` from a machine with Docker and Python 3. The script builds the image, downloads checksum-verified APK/IPA/dSYM fixtures, and starts an isolated PostgreSQL/MinIO Compose project. Test credentials in `test.env` are deliberately disposable and must never be used in production.

Services have no published ports. The bucket is private. Tests exercise real HTTP uploads, signed direct downloads, byte checksums, HTTP Range, expiry/anonymous rejection, channel passwords on both routes, iOS manifest tickets (including invalidation on password change), APK/IPA reparsing from S3, dSYM/Proguard parsing, icons, deletion, multipart uploads, export/import and backup restore. The final test runs with `ZEALOT_STORAGE=file` to check backward compatibility.

Clean up the disposable project after reviewing results:

```sh
docker compose -f test/s3/compose.yaml down -v
```

No tests use the production database or bucket. Fixtures are fetched from the pinned app-info commit in `fetch_fixtures.py`, not from moving URLs.

For the group-admin app creation regression, run `bundle exec rails runner test/s3/app_creation_access.rb` in the disposable runner after `db:prepare`. It covers the Turbo modal, managed-group choices, successful creation and ownership, rejection of unauthorized groups and ungrouped creation, and platform-admin behavior. It requires the database host `zealot-s3-test-db` and rolls back each test.

Run `bundle exec rails runner test/s3/debug_file_empty_state.rb` in the same disposable environment to check the debug-file upload button and empty-state guidance for users with no apps, active upload access, archived apps, or view-only access.

For unified Android/iOS links, create a public Android channel named `Legacy Android` with the old runtime before applying migration `20261027000000`, then run `bundle exec rails runner test/s3/unified_install_links.rb`. See `docs/unified-install-links.md` for coverage and behavior. Browser checks are in `test/ui/unified_install.cjs` and require the disposable UI fixture described in that script.
