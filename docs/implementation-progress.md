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

## Checkpoint: shared webhook isolation and cross-app debug files

The amd64 `zealot-s3:direct-preview` image built successfully and passed Zeitwerk eager loading (`/tmp/zealot-next-built-image-check.log`). It is a preview snapshot predating the webhook/checksum changes below, not a production release.

Browser byte-count verification now passed for all three fixtures: APK 4,000,563 bytes, IPA 42,699 bytes and dSYM 335,077 bytes went to the storage origin; the largest application request was 384 bytes (`/tmp/zealot-browser-direct-byte-verified.log`). Fixtures now create separate apps on each run to respect app-local duplicate-debug checks.

Fixed global debug checksum uniqueness: identical symbols can belong to different apps; each app still rejects duplicate debug records. Migration `20260907000002` adds a unique `(app_id, checksum)` index. Real HTTP uploads of the same dSYM into two apps passed, with separate object references (1 run / 9 assertions, `/tmp/zealot-next-debug-multiapp.log`).

Webhook scopes now require management of the originating app and every associated app before a shared destination can be reused or changed. Channel pages no longer expose unrelated destinations or app names. Channel authorization precedes mutations; the originating channel is server-assigned. Enable/disable/test now use POST with CSRF checks, and repeated enable does not create duplicate links. Changes are audited without copying webhook URLs or bodies. The existing admin route constraint already hides the global console; its controller/policy now also require platform admin status.

Legacy JB templates execute Ruby. Only platform admins may supply custom templates; application admins use the standard event payload. Queued webhook jobs recheck channel association and user access and skip execution in recovery mode. Fixed CI fields in the standard payload to use the supplied template variables. Tests: 6 runs / 30 assertions passed (`/tmp/zealot-next-webhook-complete.log`), plus standard payload rendering 1 run / 4 assertions (`/tmp/zealot-next-webhook-payload.log`). No webhook requests were sent to external recipients during these tests.

Remaining full-goal work is unchanged: group/storage management APIs, remaining permission/SDK/service-account audit, browser cancellation/retry and production CORS, bounded parsing and orphan reconciliation, durable notification deduplication, DB-only remote backup and recovery/migration tools, two-profile concurrent lifecycle and fresh-host/backup-point restore rehearsals, latest-image validation and production migration. Webhook guards alone do not prove recovery mode covers every background side effect.

## Checkpoint: group and storage management APIs

Added authenticated group CRUD, member list/set/removal, authorized storage choices for groups/apps, and platform-admin-only storage CRUD/check APIs. App responses include group/storage bindings and inheritance. Endpoint and request documentation is in `docs/management-api.md`.

Web and API storage writes now share `Storage::ProfileWriter`: a transaction serializes default selection, credential rotation and grant replacement. It reloads persisted profiles under the lock before applying permitted fields, preserves omitted credentials/grants, validates ID arrays, and rolls back every change on invalid grants. API responses explicitly allowlist non-secret fields; development error responses now use filtered request parameters too.

Evidence:
- `management_api.rb`: 4 runs / 53 assertions passed (`/tmp/zealot-next-management-api-verified.log`): group visibility and member revocation, grant-required bindings, secret redaction, credential rotation preserving grants, reference-protected deletion and atomic default/credential rollback.
- `management_ui.rb`: 3 runs / 20 assertions passed with the shared writer (`/tmp/zealot-next-writer-ui.log`).
- Grant-ID bounds/rollback follow-up: 1 run / 7 assertions passed (`/tmp/zealot-next-api-grants-final.log`).
- Zeitwerk eager load passed (`/tmp/zealot-next-management-zeitwerk.log`).

These route tests loaded current code in separate Rails integration processes. The long-lived production-mode test server and preview image still need refreshing before testing these APIs through the browser/server image. Production has not changed.

Browser cancellation also passed in real Chrome: a storage PUT was held while the user cancelled; the session became cancelled and no release was created (`test/s3/browser/cancel.cjs`, `/tmp/zealot-browser-cancel.log`). The cancellation screenshot was inspected.

Remaining full scope: finish permission/SDK/service-account audit; browser analysis-retry and production CORS; resource-bounded parsing, orphan reconciliation and notification deduplication; remote DB-only backups and complete recovery/migration tooling; concurrent two-profile lifecycle and fresh-host/old-backup recovery rehearsals; final current-source image validation, production migration and deployment documentation.

## Checkpoint: reconciliation and retained-object safety

Added daily managed-key orphan reconciliation, with a two-day grace period and a full retention window before deleting recovered orphan objects. Expired multipart sessions are aborted; failed analysis expires after seven days and retires its object. Parser start/manual retry/expiry now serialize on the session row. A successful publication cannot become failed because cleanup raises afterward. Purging rechecks release/debug references and isolates per-storage network failures.

Real disposable MinIO/PostgreSQL evidence: `reconciliation.rb` first four cases passed 4 runs / 22 assertions (`/tmp/zealot-next-reconciliation-complete.log`); the added failed-analysis expiry/retry case passed 1 run / 8 assertions (`/tmp/zealot-next-expiration.log`). APK parsing and SHA refusal passed 2 runs / 12 assertions after the parser locking change (`/tmp/zealot-next-parse-lock.log`).

MinIO tests exposed exact-key-only multipart enumeration and different upload-ID representations between create/list. Reconciliation therefore protects active keys independently of literal upload IDs, and falls back to exact known-key queries. Full-key loss still requires provider lifecycle cleanup on MinIO. Production R2 prefix enumeration/lifecycle remain unverified; see `docs/storage-reconciliation.md`. No production deployment occurred. Resource limits, durable notifications, backup/recovery, SDK credentials and final acceptance remain open.

## Checkpoint: bounded download and parser cleanup

Stored-object and CarrierWave parser downloads now share a streaming byte cap, default 20 GiB (`ZEALOT_PARSER_MAX_FILE_BYTES`). A direct-upload session's expected size is enforced during streaming, with undersized responses rejected before parsing. Temporary downloads are removed on all exception paths. The AWS SDK wraps streaming-consumer exceptions; known limit errors are unwrapped so the session reports the correct failure. Metadata SHA1 uses streaming reads, and its parser cleanup runs even when extraction fails.

Evidence: `local_download.rb` passed 6 runs / 23 assertions against real MinIO plus controlled streaming/parser failures (`/tmp/zealot-next-download-cleanup.log`). It checks binary integrity, oversize/undersize rejection, stopping chunk consumption, no request above the configured bound, download-file cleanup and parser cleanup on metadata failure. The multipart suite passed 12 runs / 63 assertions with 4 explicitly skipped HTTP-client cases (`/tmp/zealot-next-download-parse.log`); APK/IPA, manifest download, SHA refusal, authorization and server multipart operations ran. That suite ran before the final metadata cleanup ensure; the final cleanup failure case ran afterward.

This is a per-download bound, not yet full parser isolation: decompressed aggregate bytes, concurrent scratch space, CPU/memory and process lifetime still need worker limits. The final image and production are unchanged. Durable notifications, DB backup/recovery and all remaining full-report acceptance gates are still open.

## Checkpoint: isolated direct-upload parser processes

Direct-upload parsing now runs in a fresh Ruby process, with Linux CPU/address-space/file-size limits, disabled core dumps, a wall-clock deadline and process-group termination. Database advisory slots bound parser concurrency across workers. A child watchdog stops orphaned processes; scratch directories are shared-lock protected while active and old abandoned directories are cleaned by upload reconciliation. Failure handling compares the claimed attempt and protects newer attempts and ready results.

All direct-parser downloads, CarrierWave cache and AppInfo extraction use the job scratch directory. Inspection showed AppInfo hardcodes `/tmp` in its archive helper, so the isolated child prepends an explicit redirect; TMPDIR alone was insufficient. ZIP preflight rejects unsafe paths/symlinks, excessive entries and declared expanded size. Fixed RubyZip already validates actual entry size while extracting. Total scratch bytes/entries are polled every 250 ms, so those are termination thresholds with possible overshoot, not filesystem hard quotas. CPU, virtual memory and individual file size use kernel limits. See `docs/parser-workers.md` for settings and boundaries.

Evidence:
- `parser_isolation.rb -n /test_isolated/`: 9 runs / 32 assertions passed (`/tmp/zealot-next-isolation-verified.log`). Includes real timeout-to-failed-to-success retry without losing S3 data, old-attempt/ready protection, cross-connection concurrency exclusion, CPU/memory/file-size/scratch failures, archive rejection and active-directory-safe cleanup. The low-memory case fails at Rosetta allocation/startup under the cap; final native deployment limits still need validation.
- Real isolated APK/IPA and mismatched dSYM: 2 runs / 20 assertions passed (`/tmp/zealot-next-isolated-mobile.log`), including existing bound-storage/manifest assertions.
- External execution mode, cron disabling and queue selection verified (`/tmp/zealot-next-worker-config-final.log`).

Initial checks caught a misplaced executable being eager-loaded, a supervisor local-variable scope error and a test TimeWithZone/File.utime mismatch; all were corrected before the above passing results. Dockerfile.s3 now copies `bin/parse_upload`. No new final image has been built or deployed. The long-lived browser test server remains on old loaded code.

Remaining: audit legacy independent teardown entry points and production resource sizing; notification deduplication and restore-safe side effects; SDK/service-account workflow; browser parse-retry and R2 CORS/lifecycle; remote DB-only backup, object migration and full restore tools/rehearsals; two-profile concurrent lifecycle; current-source image, production migration and complete acceptance audit. This checkpoint does not close the full goal.

## Checkpoint: durable webhook delivery

Migration 00003 adds a transactional notification outbox. Direct and legacy uploads register their webhook events with the release transaction; download events bind the requested release. Unique upload keys and atomic claims suppress repeated registration/sending. Uncertain HTTP outcomes are not automatically resent. A scoped notification history page supports CSRF-protected, audited manual retries using the same delivery ID. Periodic scheduling reconciliation and a recovery suppression primitive are implemented; full restore orchestration remains open. No external webhook recipient was contacted during verification.

Focused integration evidence: `web_hook_delivery.rb -n /test_delivery/`, 2 runs / 22 assertions passed (`/tmp/zealot-next-delivery.log`). Uses real isolated publication and tests transactional rollback, repeat registration, old-release payload, duplicate worker invocation, HTTP timeout handling, rendered history page/manual retry/CSRF, revoked-user suppression and recovery suppression. HTTP delivery was stubbed. UI browser visual inspection and final current-source deployment remain pending; do not treat these route tests as that evidence. See `docs/webhook-delivery.md` for at-most-once automatic request behavior and manual retry ambiguity.

User reports 15% remaining usage. Prioritize remaining backup/restore/migration/deployment functionality and focused acceptance checks; avoid widening peripheral test scope or repeated image builds.

## Checkpoint: remote database backup and restore main path

Implemented PostgreSQL custom-format archives stored in S3 with separately readable SHA256/size manifests, remote verification before publication, and temporary-file cleanup. S3-mode BackupJob now exports only PostgreSQL; admin backup pages select a storage profile, list cloud manifests and issue signed downloads. Migration 00004 binds a backup plan's storage, protecting existing archive locations. Retention days override max_keeps, including manual deletion; negative max_keeps remains unlimited. Explicitly retained backup objects preserve profile references.

Added `bin/database_archive` for list/backup/restore without requiring the old database to retrieve archives, and an actual `.env.backup.example`. Restore requires recovery mode and an explicit target DB, validates the archive before single-transaction pg_restore, migrates the restored schema, suppresses old notifications, removes old jobs/cache and checks referenced object presence/size. Recovery mode blocks Web/API with 503, forces cron/execution off, and aborts all ActiveJob execution (including legacy/mailer jobs). Existing old processes must still be stopped externally before restore.

Evidence:
- Real CLI dump/upload/remote SHA256 verification produced a 192138-byte archive (`/tmp/zealot-next-db-backup.json`). Restored into separate DB `zealot_restore_20260907_a`, migrated 00004, suppressed old notifications/jobs and verified 17 references (`/tmp/zealot-next-db-restore.log`). Source DB was not overwritten.
- Fresh disposable amd64 container with current source mounted read-only and empty tmpfs, without the old upload/backup volumes: downloaded 10 packages, 5 icons and 2 debug files; all 17 SHA256 values matched (`/tmp/zealot-next-fresh-restore-read-verified.log`). This uses a preview runtime plus current source, not the final immutable image or full browser restore acceptance.
- Remote BackupJob/admin list/settings/signed download, archive contents and retention/location protection: 1 run / 15 assertions passed (`/tmp/zealot-next-remote-backup-final.log`). The initial test compared differently encoded binary strings; it now compares SHA256, avoiding huge binary failure output.
- Recovery middleware, forced external/cron-off configuration and ActiveJob halt verified (`/tmp/zealot-next-recovery-freeze.log`).

Still open: cross-storage object migration, scoped SDK/service credentials and remaining surface audit, browser parse-retry/R2 CORS/lifecycle, native production limits, old-backup-before-deletion rehearsal, concurrent two-profile lifecycle, final image/production migration and root deployment README. These concrete backup/restore results advance D/E but do not prove the complete approved report. Production remains unchanged.

## Checkpoint: cross-storage migration and dedicated service accounts

Implemented queued, audited object migrations with source advisory locks, bounded streaming download, full destination SHA256/size verification and atomic package/icon/debug reference switching. A failed copy leaves the source reference intact; a completed switch retains the original object for the database recovery window. Repeat requests reuse the task, cancellation retires the destination, and reconciliation requeues abandoned active tasks. Operator authorization is reloaded before switching. See `docs/object-migration.md`.

Added confirmed, noninteractive service accounts restricted to explicit application read/upload grants. They cannot inherit group privileges or manage apps. CLI creation, grant replacement, token rotation and revocation are audited. Permission checks reload identity to reject previously cached users after revocation; user role/lock/token changes and deletion invalidate installation tickets. See `docs/service-accounts.md` for Fastlane and SDK HTTP-header integration; third-party SDK packages have not been modified.

Evidence: real two-bucket MinIO migration passed 1 run / 34 assertions (`/tmp/zealot-next-object-migration.log`), including failure after copy, retry, all three object kinds, intact bytes and retained source. Service account integration passed 1 run / 21 assertions on final code (`/tmp/zealot-next-service-account-commit.log`), including authorized session creation, rotation, stale-user rejection and in-flight upload revocation. Migration queue scheduling was added after its transfer test; final image integration remains pending.

Production preflight found 1 application, 0 releases, 0 debug files, 1 admin and 1 member (different from the earlier empty database). Preserve this real application during migration. Production still runs `6.2.2-ec729d2d`. R2 object credentials cannot read bucket CORS/lifecycle configuration (AccessDenied); the authenticated Cloudflare dashboard showed no CORS and an enabled 7-day multipart-abort rule. Added CORS for only `https://zealot.dev.ihubin.com`, PUT/GET/HEAD, Content-Type and exposed ETag. A pre-change real R2 multipart test verified 5255225 bytes, SHA256, two listed parts, server completion, old part URL rejection (404), and abort. Post-CORS verification follows.

The bucket also has an enabled public custom domain `infra.s3.mockdata.work`; its ownership/use must be resolved before treating application files as private. User clarification is pending. Remaining E gates, production migration, immutable image and deployment README are not complete.

### Real R2 post-CORS result

`test/s3/r2_protocol.rb` ran against production R2 credentials in a unique `zealot/verification/<uuid>/` namespace and removed its test object. The final result: preflight 204, exact Zealot origin, PUT/GET/HEAD allowed, Content-Type allowed, ETag exposed; two real signed UploadPart requests; merged size 5255225 bytes and matching SHA256; old part URL rejected with 404; abort verified. Prefix-wide listing returned the key, but the returned upload ID differed from CreateMultipartUpload. The reconciler already protects active object keys independently of opaque upload ID representation. CORS configuration is versioned at `deploy/r2-cors.json`; the dashboard confirms the enabled 7-day multipart abort rule.

A HEAD of the same disposable object through `https://infra.s3.mockdata.work` returned **200 without authentication**, proving the existing public domain bypasses application-level privacy. Do not claim this bucket is private, store database backups there, or complete private-app production acceptance until public access is disabled or an independent private bucket is selected. The user has been asked whether other services depend on the public domain. This finding does not prevent the remaining local implementation and image preparation.

## Checkpoint: native build and production-clone preparation

The first native build (`6f3e89ed`) terminated before compilation because the host's configured Docker Hub mirror returned 403 for Node metadata. Commit `9b073ab2` makes the asset Node image configurable and defaults to the public ECR Docker library source. Its native amd64 build is running under image tag `zealot-s3:next-9b073ab2`, log `/tmp/zealot-next-build-9b073ab2.log` on the deployment host; asset dependency downloads are in progress. Do not infer image completion from this checkpoint.

Created a local production rollback archive at `/Users/hubin/docker-zealot/backups/pre-direct-upload-20260907-9b073ab2/`: custom PostgreSQL dump (84638 bytes), verified readable with pg_restore --list, SHA256 manifest and mode-restricted deployment configuration copies. No database backup was sent to the public R2 bucket. Restored the archive in a new, unpublished-port PostgreSQL 14 container `zealot-next-shadow-db` on network `zealot-next-acceptance`, database `zealot_shadow`; counts are 1 application, 2 users and 0 releases. Production database was not changed.

`test/s3/production_migration.rb` is prepared to validate bootstrap idempotency, retained identities, encrypted credential recovery and frozen side effects against that clone after running current migrations. It has not run yet. `deploy/production-limits.env` records capacity-based initial settings (one parser, 3 GiB address space, 4 GiB file, 8 GiB expanded ZIP, 16 GiB scratch) for the measured 8 GiB Docker VM and 37.8 GiB free overlay. Production remains on the old image; public bucket-domain clarification is still pending.

## Checkpoint: immutable native image, clone migration and real R2 parsing

Native amd64 image `zealot-s3:next-9b073ab2` built successfully: `sha256:c78207146a6871300abb8945f87d7184006651ceb3497c500134964b65a05e4e`. Image application code is commit `9b073ab2`; subsequent commits add operational/test artifacts only. No mounted application source was used in the following checks.

The immutable image migrated the production clone through `20260907000006`, imported the default R2 profile, decrypted the imported credentials, assigned the original app to the default group, and repeated bootstrap idempotently. It preserved 1 application and 2 users with their original IDs and 0 releases. Recovery verification suppressed old notifications/jobs and the Zeitwerk eager-load check passed. Evidence: deployment host `/tmp/zealot-native-migration.log`; script `test/s3/production_migration.rb`.

`test/s3/native_r2.rb` then passed against actual R2 and the isolated clone using native `x86_64-linux-musl` and `deploy/production-limits.env`. APK 4000563 bytes, IPA 42699 bytes and dSYM 335077 bytes each reached ready, had metadata, retained their SHA256 and downloaded with identical SHA256. Android's icon was present and bound to R2; repeat parser invocation did not duplicate releases. Test-only apps and their UUID objects were cleaned up. All background execution/cron stayed disabled; no external webhook was configured/contacted. Evidence: deployment host `/tmp/zealot-native-r2-final.log`. The initial script incorrectly checked an in-memory pre-parser state; explicit reload fixed the verification script without changing/rebuilding application code.

Local and deployment-host README now record the immutable image, rollback backup and production-clone migration. Production itself remains unchanged. Public custom-domain resolution still requires the pending user answer; do not upload database backups to that publicly accessible bucket. Remaining complete-report gates include the residual route/SDK and legacy parsing audit, browser parse-retry, simultaneous two-profile lifecycle, old-backup-before-deletion/full recovery acceptance and final production migration. Physical iOS installation still requires a validly signed IPA and trusted HTTPS; fixture parsing is not that evidence.

## Checkpoint: restore a database point preceding object deletion

Completed the explicit old-backup rollback gate with the original verified 192138-byte cloud archive. On isolated restored DB `zealot_restore_20260907_a`, migrated through 00006, deleted release 24 (package and icon) and debug file 10. All three objects entered future retention (>36 days). Running the actual PurgeStoredObjectsJob left their bytes/SHA256 intact. Restored the original pre-deletion cloud archive into new DB `zealot_restore_20260907_b` using `bin/database_archive`; migrations and 17-reference verification passed, and old jobs/notifications were suppressed. The old release/debug records, original package/icon/debug bindings and ready states returned; all three objects downloaded with their pre-deletion SHA256. Recovery cron remained disabled.

Evidence: `test/s3/old_backup_point.rb`, `/tmp/zealot-old-point-delete.log`, `/tmp/zealot-old-point-restore.log`, `/tmp/zealot-old-point-verified.log`. Main test DB, production DB and production bucket were not modified by this rehearsal. This proves the tested backup retention rollback, not an unbounded/cloud-account-loss recovery guarantee.

### Concurrent two-bucket package/icon lifecycle

`test/s3/concurrent_storage.rb -n /test_concurrent/` passed 1 run / 27 assertions (`/tmp/zealot-concurrent-storage.log`). Two threads in one Rails process uploaded the same real APK to two independent MinIO buckets and started overlapping isolated parser jobs. Each application's default storage was switched to the opposite profile after upload completion and before parsing. Both package and derived icon retained their original profile, metadata and exact downloaded SHA256. Deleting the resulting releases retired the original objects with future retention, and each remained readable in its own bucket. This exercises concurrent package/icon binding and deletion; debug files already have separate protocol/binding checks but were not part of this concurrent case. Production remains unchanged.

## Checkpoint: legacy parsing authorization audit

Found and fixed two actual gaps: standalone TeardownsController#create did not authorize, and its authentication callback depended on guest mode when the class loaded; it now always requires login and explicitly authorizes creation. Legacy TeardownJob now rechecks the originating user's upload access before downloading. DebugFileTeardownJob rechecks user-originated jobs, and the legacy API now passes current_user.id instead of treating requests as actorless system work. Existing actorless internal debug calls remain trusted maintenance entry points; no public controller can select that mode.

Focused evidence: `test/s3/legacy_parse_access.rb -n '/test_(revoked|guest_mode)/'` passed 2 runs / 6 assertions (`/tmp/zealot-legacy-access-final.log`), exercising revoked queued work before any download and anonymous standalone submission with a real CSRF token while guest mode is enabled. The guest check correctly expects the login redirect, not a 403 response from an action that authentication never reaches.

This changes application code after image `next-9b073ab2`, so that previously verified image is not the final deployable revision. Build once more after remaining audit changes are settled. Resource isolation currently covers direct-upload parsing, including the nested debug parser; synchronous legacy upload/standalone parsing and legacy reparse paths are compatibility behavior and should not be described as having the direct parser's process limits. Full-report readiness remains incomplete; public-bucket-domain clarification remains pending.

## Checkpoint: real-browser parse retry and final candidate image

Restarted the local Rails preview with current backend code, async `app_parse` queue only and cron disabled. Using real Chrome/native file selection, uploaded the 4000563-byte public APK to test app 221/channel `Sbw2e`, deliberately configured with `invalid.retry.fixture`. The page showed the real bundle mismatch and a visible “重试解析” button. Verified failed state and no release, recorded the retained object's ID/ETag/SHA256, corrected only the channel constraint to `*`, then clicked the browser retry button. The browser navigated to release 57 and displayed AppInfoDemo 2.1.0(10).

Backend proof: upload session `35e91a8d-75ae-427e-a02f-24d48e8cb5c6` reached ready in exactly two attempts with exactly one release and unchanged object ID, ETag and SHA256 (`/tmp/zealot-browser-retry-verified.log`). HTTP log has one parts-signing POST, one complete POST, then one retry_parse POST/202 and no second parts-signing request (`/tmp/zealot-browser-retry-server.log`). Browser state was inspected after failure and after publication. This is an actual UI retry, not a simulated success response.

Final candidate `zealot-s3:next-70689cb9` built on native amd64 with image ID `sha256:c5697ca7c3676d64765695dc34eaeec8b499d4f4db57e4117b7e6b9c91c1a1aa`; it includes the legacy authorization fixes. Current migrations, bootstrap idempotency, production-clone record preservation, decryption/recovery verification and Zeitwerk passed in that immutable image (`/tmp/zealot-final-migration.log` on deployment host). No later application code changes are present. Production still runs the original stable image; public domain resolution and production acceptance remain pending.

## Checkpoint: prepared cutover configuration and domain correction

Prepared `deploy/compose.production-next.yaml` and `docs/production-cutover.md`; copied the overlay and parser limits to the deployment directory and validated `docker compose ... config --quiet` successfully. Production remains on the original healthy image; no production migration or switch has run.

The user clarified the custom domain has no other use, then explicitly instructed **do not disable it**. It had just been disabled in the dashboard; immediately restored it and verified “已启用”. Keep `infra.s3.mockdata.work` enabled. A privacy probe run during the temporary disabled interval returned signed download 200 with matching bytes, unsigned S3 400, custom domain 401; that is NOT evidence of its current re-enabled state. Its test object was removed. Asked whether the retained custom domain should provide public or authorized package downloads. Do not infer a privacy waiver or change the domain again while that choice is pending.


## 公开下载确认（2026-09-07）

用户明确保留 `infra.s3.mockdata.work` 启用，用于公开下载安装包。此前私有包下载的要求由此调整：管理、上传、应用页面仍校验账号权限；获得 R2 对象地址后可匿名下载，Zealot 撤销成员权限不会撤销该公开 URL。新增 `public_download_origin`，不复用 S3 签名 Endpoint。公开桶禁止数据库备份写入（包括同桶的其他存储配置）。新增私有桶 `zealot-backups`，当前对象密钥无该桶权限，已向用户索取独立读写凭据。新增定向测试 1 项 / 12 断言通过，覆盖 URL 编码、上传签名地址、备份隔离与位置不可变。
