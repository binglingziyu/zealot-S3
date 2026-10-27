# Run only against an isolated clone of production, with recovery mode enabled.
raise 'Recovery mode required' unless ENV['ZEALOT_RECOVERY_MODE'] == 'true'
raise 'Explicit shadow database required' unless ActiveRecord::Base.connection_db_config.database == 'zealot_shadow'
raise 'Jobs must be external' unless GoodJob.configuration.execution_mode == :external
raise 'Cron must be disabled' if Rails.application.config.good_job.enable_cron
before = { apps: App.order(:id).pluck(:id), users: User.order(:id).pluck(:id), releases: Release.order(:id).pluck(:id) }
preview = Storage::Bootstrap.preview
profile = Storage::Bootstrap.call
raise 'Default storage import missing' unless profile.system_default? && profile.bucket == ENV.fetch('ZEALOT_S3_BUCKET')
raise 'Credentials did not survive encryption' unless profile.reload.credentials.fetch('access_key_id') == ENV.fetch('ZEALOT_S3_ACCESS_KEY_ID')
raise 'Applications were not grouped' if App.where(group_id: nil).exists?
after = { apps: App.order(:id).pluck(:id), users: User.order(:id).pluck(:id), releases: Release.order(:id).pluck(:id) }
raise 'Legacy records changed identity' unless before == after
raise 'Bootstrap was not idempotent' unless Storage::Bootstrap.call.id == profile.id
verification = Recovery::DatabaseVerifier.call
puts JSON.generate(preview: preview, preserved_counts: after.transform_values(&:size), storage_imported: true,
  bootstrap_idempotent: true, recovery: verification, schema: ActiveRecord::Migrator.current_version)
