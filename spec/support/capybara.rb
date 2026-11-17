# frozen_string_literal: true

require "capybara/cuprite"
require "capybara/rspec"
require_relative "chromium_availability"

# Note: this is registered as `:paid_cuprite`, not `:cuprite`, on purpose.
# Rails' `driven_by(:cuprite)` has a built-in mapping that ignores
# `Capybara.register_driver(:cuprite)` and instantiates Cuprite with
# default options — so `process_timeout`, `browser_path`, and our flags
# get silently dropped. Using a unique name forces Capybara's registry
# (which honors this block) instead. If you add system specs, use
# `driven_by :paid_cuprite` (already wired below for `type: :system`).
Capybara.register_driver(:paid_cuprite) do |app|
  Capybara::Cuprite::Driver.new(
    app,
    headless: ENV.fetch("HEADLESS", "true") != "false",
    js_errors: true,
    timeout: 15,
    process_timeout: 60,
    browser_path: ChromiumAvailability.chromium_path || "/usr/bin/chromium",
    browser_options: {
      "no-sandbox": nil,
      "disable-dev-shm-usage": nil,
      "disable-gpu": nil,
      "disable-software-rasterizer": nil
    }
  )
end

SYSTEM_DRIVER = :rack_test

# A Cuprite/Puma request checks out a different connection from the example.
# Wrap the complete Rack stack so Warden can deserialize the session user before
# ApplicationController resolves and applies the signed-in user's tenant.
# @spec POSTGRESQL-PERSISTENCE-012
class CapybaraTenantContext
  def initialize(app)
    @app = app
  end

  def call(environment)
    TenantContext.with_system_access { @app.call(environment) }
  end
end

Capybara.app = CapybaraTenantContext.new(Rails.application)

# The Puma server starts each request through the Rails executor. Establish the
# same baseline on its checked-out connection before middleware deserializes the
# Warden session; the Rack wrapper above also covers Capybara's direct app path.
# @spec POSTGRESQL-PERSISTENCE-012
Rails.application.executor.to_run { TenantContext.apply_system_access! }

# RackTest and the example share a database connection. ApplicationController
# deliberately clears request tenant context, so restore the test harness's
# system-access baseline before assertions run on that shared connection.
# Browser-driven specs use a separate server connection and do not need this.
# @spec POSTGRESQL-PERSISTENCE-012
module RackTestTenantContext
  def process(...)
    super
  ensure
    TenantContext.apply_system_access!
  end
end

Capybara::RackTest::Browser.prepend(RackTestTenantContext)

Capybara.server = :puma, { Silent: true }
Capybara.server_host = "127.0.0.1"
Capybara.default_max_wait_time = 5

RSpec.configure do |config|
  config.before(:each, type: :system) do |example|
    driven_by example.metadata.fetch(:system_driver, SYSTEM_DRIVER)
  end

  # System specs drive a real browser, so CSRF must actually be enforced.
  # Request specs run with allow_forgery_protection = false (see
  # config/environments/test.rb); flip it back on for system specs only,
  # otherwise the whole point — fidelity to production auth flow — is lost.
  config.around(:each, type: :system) do |example|
    previous = ActionController::Base.allow_forgery_protection
    ActionController::Base.allow_forgery_protection = true
    example.run
  ensure
    ActionController::Base.allow_forgery_protection = previous
  end
end
