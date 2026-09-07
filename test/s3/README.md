# S3 integration tests

Run `./test/s3/run.sh` from a machine with Docker and Python 3. The script builds the image, downloads checksum-verified APK/IPA/dSYM fixtures, and starts an isolated PostgreSQL/MinIO Compose project. Test credentials in `test.env` are deliberately disposable and must never be used in production.

Services have no published ports. The bucket is private. Tests exercise real HTTP uploads, signed direct downloads, byte checksums, HTTP Range, expiry/anonymous rejection, channel passwords on both routes, iOS manifest tickets (including invalidation on password change), APK/IPA reparsing from S3, dSYM/Proguard parsing, icons, deletion, multipart uploads, export/import and backup restore. The final test runs with `ZEALOT_STORAGE=file` to check backward compatibility.

Clean up the disposable project after reviewing results:

```sh
docker compose -f test/s3/compose.yaml down -v
```

No tests use the production database or bucket. Fixtures are fetched from the pinned app-info commit in `fetch_fixtures.py`, not from moving URLs.
