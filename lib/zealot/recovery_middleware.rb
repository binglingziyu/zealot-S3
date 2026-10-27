# frozen_string_literal: true

module Zealot
  class RecoveryMiddleware
    def initialize(app)
      @app = app
    end

    def call(environment)
      return @app.call(environment) unless ENV['ZEALOT_RECOVERY_MODE'] == 'true'
      [503, { 'content-type' => 'application/json', 'cache-control' => 'no-store' },
        ['{"error":"Recovery mode: verify the restored database before opening the service"}']]
    end
  end
end
