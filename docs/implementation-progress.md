# Implementation acceptance ledger

Goal: implement the entire approved feasibility report, not only storage-compatible changes.
Branch: feature/direct-upload-groups. Production remains on the verified S3 build until migration rehearsals pass.

- [ ] A: schema, groups/memberships, access resolver, profile credentials and immutable object references; migration/backfill tests.
- [ ] B: group/application management UI and APIs; all read/download/signing surfaces scoped; role migration, CSRF, revocation and isolation tests.
- [ ] C: persistent multipart upload sessions, server-only completion, byte verification, parser retry/reconciliation, browser and Fastlane direct clients including debug files.
- [ ] D: application/group/default storage binding, fixed historic locations, delayed object deletion, DB-only backup/restore and externally retained encryption keys.
- [ ] E: two-profile concurrency tests, interrupted upload/migration recovery, fresh-host restore and backup-point recovery, final image, production migration, end-to-end checks and documentation.

Do not mark the goal complete until all report acceptance conditions have authoritative evidence. Existing MinIO/R2 tests cover the previous S3 feature only.

## Checkpoint: foundations and first management surfaces

Implemented (not yet deployed): schema for groups, grants, storage profiles, stored objects, multipart sessions and audit events; shared access resolver; encrypted profile credentials with immutable referenced locations; rerunnable ENV/legacy-object bootstrap; group/member and storage management pages; scoped app/channel/release/debug API entry points and private download guards; CSRF enabled for browser management (Apple enrollment callback excepted).

Evidence from isolated PostgreSQL/MinIO on this branch:
- foundation.rb: 7 runs / 40 assertions passed.
- bootstrap.rb: 1 run / 12 assertions passed (legacy object keys/ETags preserved, role grants and rerun checked).
- private_routes.rb: 2 runs / 20 assertions passed.
- management_ui.rb: 3 runs / 20 assertions passed (real rendered forms, credential redaction, member denial, CSRF rejection).
- Zeitwerk eager load passed.

Still required before any production switch: complete per-object CarrierWave binding, multipart service/controllers/jobs and retry/cleanup, browser and Fastlane clients, full permission-surface audit (including shared webhooks and SDK/service credentials), group/storage APIs, audit coverage, visual browser checks, delayed deletion/backup/restore, profile migration, integration suite update to private-by-default semantics, two-profile tests and deployment rehearsal. The above tests are a checkpoint, not proof that the full report is implemented.

Test environment: Docker network zealot-next-test; containers zealot-next-db (Postgres 17), zealot-next-store (MinIO), zealot-next-runner (zealot-s3:dev with source mounts). No published ports and no production credentials. Runner routes/filter initializer were copied in; app/db/lib/test are mounted. Recreate/build the final image with full config/db before release. Logs: /tmp/zealot-next-{foundation-final,access-final,ui-final,zeitwerk-final}.log.

## Checkpoint: direct upload protocol and first clients

Implemented in the worktree: immutable CarrierWave object bindings for package/icon/debug files; retained object references after record deletion; multipart initiation/signing/listing/server completion/cancellation; real byte/SHA256 verification and asynchronous package/debug parsing; failed-analysis retry and initial reconciliation/GC jobs. API bearer authentication and browser session/CSRF controllers share the same actions. Web upload pages now use chunked SHA256, three concurrent direct storage uploads, resumable parts, cancellation and analysis polling/retry. The Fastlane plugin includes a dependency-free Ruby client, bounded part concurrency/retries, resumption and the existing lane output keys.

Verified against disposable PostgreSQL/MinIO and a real Rails HTTP server:
- `test/s3/multipart.rb`: 11 runs / 71 assertions passed in `/tmp/zealot-next-direct-suite.log`. Covers real APK/IPA/dSYM parsing, 20 MiB two-part Ruby client upload, resuming already stored parts, idempotent published results, storage binding after app profile changes, server-only completion/recovery, SHA mismatch refusal, browser form rendering and CSRF-protected control requests/cancellation.
- Additional ownership/revocation test: 1 run / 10 assertions passed in `/tmp/zealot-next-revoke.log`. Another uploader cannot sign/list/complete/cancel a session, and removing its owner's upload role prevents publication.
- JavaScript production bundle and syntax check passed; Rails Zeitwerk eager load passed (`/tmp/zealot-next-direct-zeitwerk.log`).

Subsequent integration evidence: Fastlane 2.228.0 was installed under `/tmp/fastlane-gems` using the image's existing compiled gems after an initial missing-compiler failure. The real action passed configuration, upload, publication and lane output assertions (`/tmp/zealot-next-fastlane-action.log`). Real headless Chrome uploads of APK, IPA and dSYM all published successfully (`/tmp/zealot-browser-direct-verified.log`); screenshots of the form and debug result were inspected. Requests went to the storage bridge and the largest application control body was 383 bytes. Browser interruption testing aborted part 2 three times, resumed it successfully and confirmed part 1 was sent once (`/tmp/zealot-browser-resume.log`). The test driver is being strengthened to record Content-Length because Playwright omits Blob bytes from `postDataBuffer`.

The browser dSYM test initially used an unrelated IPA in the same app and was correctly rejected. Fixtures now separate these apps. Strict debug parsing now preserves the specific bundle-ID error instead of hiding it behind a generic failure; the negative test with a real IPA and mismatched dSYM passed (1 run / 12 assertions, `/tmp/zealot-next-debug-error-verified.log`).

The test web server runs on port 3001 inside `zealot-next-runner`. Local-only bridge containers `zealot-next-preview` and `zealot-next-storage-preview` publish 127.0.0.1:18902 and 127.0.0.1:18903 for browser tests. Reproducible fixture/driver sources are in `test/s3/browser`. Copy client updates with `docker cp clients/. zealot-next-runner:/app/clients/` (copying the directory into an existing directory nests it and can leave old code active). Routes must also be copied and the production-mode test web server restarted after controller changes. Do not restart merely on a log/poll timeout.

Still required: finish browser cancellation/retry and production CORS verification; parser resource limits and robust orphan multipart/object reconciliation; notification deduplication; remaining group/storage APIs, SDK/service-account workflow and shared-webhook permission audit; database-only remote backup, recovery mode across all side effects, restore/reconciliation/migration tooling; two-profile concurrent lifecycle and fresh-host/old-backup recovery rehearsals; final image and production migration/documentation. Existing production remains on the previous verified S3 image. Dockerfile.s3 now builds the new JS/CSS and font assets instead of retaining the old upload bundle; an amd64 preview build is running, log `/tmp/zealot-next-image-build.log`, and is not yet validated.
