#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
python3 test/s3/fetch_fixtures.py
docker build -f Dockerfile.s3 -t zealot-s3:test .
# Use a dedicated Compose project and unpublished services.
docker compose -f test/s3/compose.yaml up -d --wait postgres minio
docker compose -f test/s3/compose.yaml run --rm runner sh -c '
  bundle exec rails runner "c = Zealot::Storage::S3.client; begin; c.create_bucket(bucket: Zealot::Storage::S3.bucket); rescue Aws::S3::Errors::BucketAlreadyOwnedByYou; end" &&
  bundle exec rails db:prepare &&
  bundle exec rails runner test/s3/integration.rb &&
  ZEALOT_STORAGE=file bundle exec rails runner test/s3/local_regression.rb
'
