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
