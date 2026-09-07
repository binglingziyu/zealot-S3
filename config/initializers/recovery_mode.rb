# frozen_string_literal: true

require_relative '../../lib/zealot/recovery_middleware'
Rails.application.config.middleware.insert_before(0, Zealot::RecoveryMiddleware)
ActiveSupport.on_load(:active_job) do
  before_perform { throw(:abort) if ENV['ZEALOT_RECOVERY_MODE'] == 'true' }
end
