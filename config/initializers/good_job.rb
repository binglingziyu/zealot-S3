# frozen_string_literal: true

CRON_JOBS_SETUP = lambda do
  cron_jobs = {
    reconcile_web_hook_deliveries: {
      cron: '* * * * *', class: 'ReconcileWebHookDeliveriesJob', description: 'Recover pending webhook delivery scheduling without resending uncertain requests'
    },
    reconcile_storage: {
      cron: '35 3 * * *', class: 'ReconcileStorageJob', description: 'Retire orphan objects and abort unknown stale multipart uploads'
    },
    reconcile_uploads: {
      cron: '*/5 * * * *', class: 'ReconcileUploadsJob', description: 'Recover stalled direct uploads'
    },
    purge_stored_objects: {
      cron: '15 4 * * *', class: 'PurgeStoredObjectsJob', description: 'Purge unreferenced objects after the recovery window'
    },
    sync_apple_devices: {
      cron: '0 0 * * *',
      class: 'SyncAppleDevicesJob',

      description: 'Syncing devices for all Apple Developers on each 0AM',
    },
    clean_old_releases: {
      cron: '0 6 * * *',
      class: 'CleanOldReleasesJob',
      description: 'Clean old versions on each 6AM',
    },
    reset_for_demo_mode: {
      cron: '0 0 * * *',
      class: 'ResetForDemoModeJob',
      description: 'Reset demo data everyday'
    }
  }

  cron_jobs.delete(:clean_old_releases) if Setting.keep_uploads
  cron_jobs.delete(:reset_for_demo_mode) unless Setting.demo_mode

  begin
    Backup.enabled_jobs.each do |backup|
      cron_jobs[backup.schedule_key] = backup.schedule_job
    end
  rescue ActiveRecord::ConnectionNotEstablished
    # ignore, maybe executing `rails assets:precompile`
  end

  cron_jobs
end

Rails.application.reloader.to_prepare do
  Rails.application.configure do
    # config.good_job.dashboard_default_locale = I18n.default_locale # no zh-cn locale
    config.good_job.preserve_job_records = true
    config.good_job.retry_on_unhandled_error = false
    config.good_job.on_thread_error = -> (exception) { Rails.error.report(exception) }
    isolated = ENV['ZEALOT_PARSER_CHILD'] == 'true' || ENV['ZEALOT_RECOVERY_MODE'] == 'true'
    execution_mode = isolated ? 'external' : ENV.fetch('ZEALOT_JOB_EXECUTION_MODE', 'async')
    raise ArgumentError, 'ZEALOT_JOB_EXECUTION_MODE must be async or external' unless %w[async external].include?(execution_mode)
    config.good_job.execution_mode = execution_mode.to_sym
    config.good_job.queues = ENV.fetch('ZEALOT_JOB_QUEUES', '*')
    config.good_job.max_threads = (ENV['ZEALOT_WORKER_CONCURRENCY'] || '5').to_i
    config.good_job.poll_interval = (ENV['ZEALOT_WORKER_POLL_INTERVAL'] || '30').to_i
    config.good_job.shutdown_timeout = (ENV['ZEALOT_WORKER_SHUTDOWN_TIMEOUT'] || '30').to_i

    begin
      config.good_job.enable_cron = !isolated && ENV.fetch('ZEALOT_ENABLE_CRON', 'true') == 'true'
      config.good_job.cron = CRON_JOBS_SETUP.call
    rescue ActiveRecord::StatementInvalid
      # initialize zealot, ignore
    end
  end
end

ActiveSupport.on_load(:good_job_application_controller) do
  content_security_policy do |policy|
    policy.frame_ancestors(:self)
  end
end
