# frozen_string_literal: true
namespace :zealot do
  namespace :storage do
    desc 'Preview or apply group/role and object-reference backfill (APPLY=1 writes DB; never copies/deletes cloud files)'
    task bootstrap: :environment do
      puts Storage::Bootstrap.preview.to_json
      if ENV['APPLY'] == '1'
        Storage::Bootstrap.call
        puts 'Backfill completed. Existing object locations preserved.'
      else
        puts 'Preview only. Back up the database and set APPLY=1 to apply.'
      end
    end
  end
end
