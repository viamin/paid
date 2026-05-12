# frozen_string_literal: true

# This file is copied to spec/ when you run 'rails generate rspec:install'
require "spec_helper"
ENV["RAILS_ENV"] ||= "test"
require_relative "../config/environment"

# Prevent database truncation if the environment is production
abort("The Rails environment is running in production mode!") if Rails.env.production?
require "fixture_kit/rspec"
require "rspec/rails"
require "test_prof/recipes/rspec/factory_default"

ActiveRecord.verify_foreign_keys_for_fixtures = false

# Add additional requires below this line. Rails is not loaded until this point!

# Requires supporting ruby files with custom matchers and macros, etc,
# in spec/support/ and its subdirectories. Files matching `spec/**/*_spec.rb` are
# run as spec files by default.
Dir[Rails.root.join("spec/support/**/*.rb")].each { |f| require f }

# Checks for pending migrations and applies them before tests are run.
# If you are not using ActiveRecord, you can remove these lines.
database_available = begin
  ActiveRecord::Migration.maintain_test_schema!
  true
rescue ActiveRecord::PendingMigrationError => e
  abort e.to_s.strip
rescue ActiveRecord::ConnectionNotEstablished => e
  if ENV["ALLOW_DBLESS_SPECS"] == "true"
    warn "[WARN] ActiveRecord::ConnectionNotEstablished during test schema maintenance: #{e.message}. " \
         "Continuing because ALLOW_DBLESS_SPECS=true; transactional fixtures will be disabled."
    false
  else
    abort <<~MSG
      ActiveRecord::ConnectionNotEstablished while preparing the test database.
      This usually means your test database is misconfigured or unavailable.

      The test suite is configured to fail fast in this situation to avoid misleading
      green runs when the database is down.

      If you intentionally want to run specs without a database (for example, tests
      that only use mocks), set ALLOW_DBLESS_SPECS=true in the environment.
    MSG
  end
end

RSpec.configure do |config|
  if ENV["CI"].present? || ENV["GITHUB_ACTIONS"].present?
    config.filter_run_excluding local_only: true
  end

  # Remove this line if you're not using ActiveRecord or ActiveRecord fixtures
  config.fixture_paths = [ Rails.root.join("spec/fixtures") ]

  # If you're not using ActiveRecord, or you'd prefer not to run each of your
  # examples within a transaction, remove the following line or assign false
  # instead of true.
  config.use_transactional_fixtures = database_available

  # You can uncomment this line to turn off ActiveRecord support entirely.
  # config.use_active_record = false

  # RSpec Rails can automatically mix in different behaviours to your tests
  # based on their file location, for example enabling you to call `get` and
  # `post` in specs under `spec/controllers`.
  config.infer_spec_type_from_file_location!

  # Filter lines from Rails gems in backtraces.
  config.filter_rails_from_backtrace!
  # arbitrary gems may also be filtered via:
  # config.filter_gems_from_backtrace("gem name")

  # Include Devise test helpers
  config.include Devise::Test::IntegrationHelpers, type: :request

  # Include ActiveSupport time helpers (freeze_time, travel_to, etc.)
  config.include ActiveSupport::Testing::TimeHelpers

  # Reset memoized provider support data between tests
  config.after do
    RunnerSupport.reset_supported_runner_keys!
  end

  config.filter_run_excluding :provider_smoke unless ENV["RUN_PROVIDER_SMOKE"] == "true"
  config.filter_run_excluding :chat_e2e unless ENV["RUN_CHAT_E2E"] == "true"

  config.around(:each, :provider_smoke) do |example|
    WebMock.allow_net_connect!
    example.run
  ensure
    WebMock.disable_net_connect!(allow_localhost: true)
  end

  config.around(:each, :chat_e2e) do |example|
    WebMock.allow_net_connect!
    example.run
  ensure
    WebMock.disable_net_connect!(allow_localhost: true)
  end

  config.around do |example|
    run_example = proc do
      if database_available && !example.metadata[:tenant_isolation]
        TenantContext.with_system_access { example.run }
      else
        example.run
      end
    end

    if ENV["PROSOPITE"] == "true"
      Prosopite.scan { run_example.call }
    else
      run_example.call
    end
  ensure
    next unless database_available

    begin
      TenantContext.clear!
    rescue ActiveRecord::StatementInvalid => error
      raise unless error.cause.is_a?(PG::InFailedSqlTransaction)
    end
  end

  # When running without a database (ALLOW_DBLESS_SPECS=true), automatically skip
  # examples that need a database connection. This lets the non-DB specs run and
  # report results while DB-dependent specs are marked as pending.
  unless database_available
    config.before do |example|
      # Only run specs under spec/lib/ or those tagged :no_db which don't need
      # a database. All other specs are skipped to avoid connection errors.
      spec_file = example.metadata[:file_path].to_s
      unless spec_file.start_with?("./spec/lib/", "spec/lib/") || example.metadata[:no_db]
        skip "Database not available (ALLOW_DBLESS_SPECS=true)"
      end
    end
  end
end
