# S3 verification — 2026-09-07

Implementation commit: `ec729d2d` (based on upstream 6.2.2).

The Docker image was built on the deployment host (Intel/amd64) and tested using an isolated PostgreSQL 14 and private MinIO bucket. No production database or storage credentials were used.

- S3 integration: **11 tests, 88 assertions, zero failures/errors/skips**.
- Local filesystem regression: **1 test, 8 assertions, zero failures/errors/skips**.
- Rails Zeitwerk check passed on the local ARM64 test image.

Coverage includes API uploads and download redirects, exact downloaded bytes, private bucket access, signed URL expiry and Range requests, channel passwords, failed S3 uploads, missing objects, APK/IPA parsing and reparsing, iOS manifest tickets and password rotation, debug archive downloads and parsing, icon storage, deletion, a 105 MiB multipart upload, export/import and backup restoration. See `test/s3/integration.rb` for assertions.

These results prove the tested MinIO S3 workflow. AWS and OSS endpoints were not tested. iOS installation on a physical device was not tested; fixture tests verify the manifest and package delivery.

## Production Cloudflare R2 verification

The amd64 image `zealot-s3:6.2.2-ec729d2d` was activated with `ZEALOT_STORAGE=s3`, region `auto` and a private R2 bucket on the deployment host. The database and configuration were backed up before activation, and the local upload migration completed.

Real APK and IPA fixtures were uploaded through the public Zealot domain from a separate client. Both requests returned HTTP 201. The normal download routes returned redirects to signed HTTPS R2 URLs; direct R2 downloads matched the original SHA256, Range requests returned 206 with matching bytes, and unsigned access was denied. The iOS manifest was fetched through the public domain and its signed package URL passed the same download checks.

Both releases had parsed metadata and no final package file under local `public/uploads`. The Android icon was present in R2; the small IPA fixture contains no icon. Deleting the temporary verification application removed its two packages and Android icon: its R2 object count went from three to zero, and the database returned to its original zero-app/zero-release state.

The existing Zealot domain certificate check was bypassed for these application requests, as certificate repair was explicitly deferred. R2 HTTPS downloads used normal certificate verification. Physical iOS device installation remains untested.
