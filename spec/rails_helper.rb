# frozen_string_literal: true

# This file is copied to spec/ when you run 'rails generate rspec:install'
require "spec_helper"
ENV["RAILS_ENV"] ||= "test"
require_relative "../config/environment"
# Prevent database truncation if the environment is production
abort("The Rails environment is running in production mode!") if Rails.env.production?
require "rspec/rails"

def ensure_test_assets_compiled!
  builds_dir = File.expand_path("../app/assets/builds", __dir__)
  required_assets = %w[application.css application.js]

  return if required_assets.all? { |asset| File.exist?(File.join(builds_dir, asset)) }

  env = {
    "YARN_CACHE_FOLDER" => File.expand_path("../.yarn-cache", __dir__)
  }

  abort "Failed to build test JavaScript assets" unless system(env, "yarn", "build")
  abort "Failed to build test CSS assets" unless system(env, "yarn", "build:css")
end

ensure_test_assets_compiled!

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
    ProviderSupport.reset_supported_provider_keys!
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
