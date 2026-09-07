# S3 storage (6.2.2 fork)

This branch extends upstream 6.2.2, the deployed version. It intentionally does not upgrade the application to the fork's develop/7.x branch. It supports private AWS S3 and compatible endpoints including MinIO and OSS's S3 API.

## Behavior

- `ZEALOT_STORAGE=file` (default): original local filesystem behavior.
- `ZEALOT_STORAGE=s3`: installation packages, release icons and debug archives are stored in a private bucket. CarrierWave upload staging remains local. Large uploads use SDK multipart streaming. A failed storage operation fails the upload instead of reporting a successful local-only upload.
- Synchronous APK/IPA parsing uses the staged upload. Background/reprocessing jobs stream a temporary copy from S3 and remove it on completion or exception.
- Normal downloads validate channel passwords and redirect to expiring signed object URLs. Both entry and filename download routes are checked. Debug downloads retain their existing authorization policy.
- iOS manifests contain signed object URLs. A short-lived release-specific install ticket allows the iOS installer to fetch a protected manifest without browser cookies. Changing the channel password invalidates existing manifest tickets. Already issued S3 URLs remain valid until their expiry.
- Objects do not require public-read ACLs. Download URLs are bearer credentials; do not log/share them beyond intended recipients.
- Deleting releases/debug files invokes S3 object deletion, including icons. Bucket versioning may retain noncurrent versions; manage their lifecycle in the bucket.
- Existing backup exports materialize remote uploads into temporary disk space before creating the portable archive. Restore imports the extracted uploads into S3. The final backup archive remains in the configured local backup volume.

## Configuration

Use `.env.s3.example`. Keep real credentials in a mode-600 file outside version control. Set the same variables on web and job workers.

| Variable | Meaning |
|---|---|
| `ZEALOT_STORAGE` | `file` or `s3` |
| `ZEALOT_S3_BUCKET` | Existing private bucket |
| `ZEALOT_S3_REGION` | Signing region, default `us-east-1` |
| `ZEALOT_S3_ENDPOINT` | Optional S3 API endpoint; omit for AWS |
| `ZEALOT_S3_DOWNLOAD_ENDPOINT` | Optional separate public S3 endpoint for signatures |
| `ZEALOT_S3_ACCESS_KEY_ID`, `ZEALOT_S3_SECRET_ACCESS_KEY` | Optional explicit credentials; otherwise SDK credential chain |
| `ZEALOT_S3_SESSION_TOKEN` | Optional temporary credential token |
| `ZEALOT_S3_FORCE_PATH_STYLE` | `true` for MinIO/path-style endpoints; default `false` |
| `ZEALOT_S3_PREFIX` | Object key prefix, e.g. `zealot` |
| `ZEALOT_S3_URL_EXPIRES_IN` | Signed URL/ticket lifetime, seconds, 1–604800; default 3600 |

For OSS, use the provider's S3-compatible endpoint and signing region, not an assumed interchangeable OSS native endpoint. The download endpoint must be reachable by devices and accept S3 signatures; replacing the hostname after signing or using an arbitrary CDN domain will invalidate signatures. Use HTTPS with a trusted certificate for iOS.

The service still receives and parses uploads. Package downloads go directly from object storage to the device and bypass frp. Local temporary space is still needed for uploaded/parsed files and backup exports.

### Cloudflare R2

Use the bucket's S3 API credentials (Access Key ID and Secret Access Key), not a Cloudflare management API token. Set `ZEALOT_S3_REGION=auto` and `ZEALOT_S3_FORCE_PATH_STYLE=true`. For a standard bucket, the endpoint is `https://<ACCOUNT_ID>.r2.cloudflarestorage.com`; use the endpoint shown by Cloudflare for jurisdiction-specific buckets. Set the bucket name separately in `ZEALOT_S3_BUCKET`.

Leave `ZEALOT_S3_DOWNLOAD_ENDPOINT` unset to sign downloads against the same public S3 API endpoint. Keep the bucket private; neither an `r2.dev` URL nor a custom public domain is needed for this signed-download implementation.

Permissions: scoped `GetObject`, `PutObject`, `DeleteObject`, `AbortMultipartUpload` on the configured object prefix; bucket `ListBucket` for export/check and `GetBucketLocation` where required by the provider. Do not give the app permission to create buckets or alter policies.

## Build and deployment

```sh
docker build -f Dockerfile.s3 -t zealot-s3:6.2.2-s3 .
```

The extension image pins the upstream runtime digest, preserves its compiled frontend assets and installs locked S3 SDK dependencies. The original Dockerfile also builds the full application with this code.

Update the deployment Compose image and add `.env.s3` to `env_file` **after** `.env`. Keep existing database/uploads/backup volumes, proxy configuration and `SECRET_KEY_BASE`. Back up the database and Compose configuration first. For configuration validation:

```sh
docker compose run --rm --entrypoint /bin/sh zealot -c "cd /app && bin/rails zealot:storage:check"
```

## Existing uploads / rollback

Stop new uploads and background jobs during the migration window. Configure S3 credentials with `ZEALOT_STORAGE=file` first:

```sh
bin/rails zealot:storage:migrate
```

The task copies local `public/uploads` into the same key layout in S3, verifying the SHA256 of bytes read back from S3 plus size, and retains local files. It is retryable. After successful copy, switch **all** processes to `ZEALOT_STORAGE=s3`. Do not switch storage with unmigrated files: mixed backend lookup is not implicit.

Before reverting to local storage after new S3 uploads:

```sh
STORAGE_EXPORT_PATH=/safe/export/uploads bin/rails zealot:storage:export
```

Copy the exported tree into the uploads volume while writers are stopped, switch to `file`, and restart. Rolling back only the image without exporting newer S3 objects would hide those newer files. There are no schema migrations in this change.

## Verification

`test/s3` contains HTTP/model integration tests against an isolated private MinIO bucket and PostgreSQL. Tests cover signed direct downloads, bytes/checksums, Range, expiry and anonymous rejection, protected filename routes, real APK/IPA parsing, iOS manifest handoff, remote dSYM/Proguard parsing, icons, removal, export/import and backup restore. Local filesystem regression tests run separately with `ZEALOT_STORAGE=file`.

Fixture downloads are pinned and checksum-verified by `test/s3/fetch_fixtures.py`. Actual device installation requires a valid signed package, provisioning and trusted HTTPS; fixture tests validate manifests and package delivery, not on-device signing/provisioning.
