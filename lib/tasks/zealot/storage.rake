# frozen_string_literal: true

namespace :zealot do
  namespace :storage do
    desc 'Copy local uploads to S3 and verify downloaded bytes; does not delete local files'
    task migrate: :environment do
      Zealot::Storage::Transfer.import_from(Rails.root.join('public/uploads').to_s)
      puts 'S3 migration verified. Local files retained. Switch ZEALOT_STORAGE=s3 and restart all workers.'
    end

    desc 'Export S3 uploads to STORAGE_EXPORT_PATH for backup or rollback'
    task export: :environment do
      directory = ENV.fetch('STORAGE_EXPORT_PATH')
      FileUtils.mkdir_p(directory)
      Zealot::Storage::Transfer.export_to(directory)
      puts 'S3 export complete.'
    end

    desc 'Validate S3 bucket access and URL expiry configuration without changing data'
    task check: :environment do
      Zealot::Storage::S3.expires_in
      Zealot::Storage::S3.client.head_bucket(bucket: Zealot::Storage::S3.bucket)
      puts 'S3 bucket reachable.'
    end
  end
end
