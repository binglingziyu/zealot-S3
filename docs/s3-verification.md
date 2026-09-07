# S3 verification — 2026-09-07

Implementation commit: `ec729d2d` (based on upstream 6.2.2).

The Docker image was built on the deployment host (Intel/amd64) and tested using an isolated PostgreSQL 14 and private MinIO bucket. No production database or storage credentials were used.

- S3 integration: **11 tests, 88 assertions, zero failures/errors/skips**.
- Local filesystem regression: **1 test, 8 assertions, zero failures/errors/skips**.
- Rails Zeitwerk check passed on the local ARM64 test image.

Coverage includes API uploads and download redirects, exact downloaded bytes, private bucket access, signed URL expiry and Range requests, channel passwords, failed S3 uploads, missing objects, APK/IPA parsing and reparsing, iOS manifest tickets and password rotation, debug archive downloads and parsing, icon storage, deletion, a 105 MiB multipart upload, export/import and backup restoration. See `test/s3/integration.rb` for assertions.

These results prove the tested MinIO S3 workflow. Actual AWS/OSS provider configuration and external signed downloads still require validation against the selected production bucket. iOS installation on a physical device was not tested; fixture tests verify the manifest and package delivery.
