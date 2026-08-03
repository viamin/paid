# frozen_string_literal: true

require "capybara/cuprite"
require "capybara/rspec"

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
    browser_path: ENV["CHROMIUM_PATH"] || "/usr/bin/chromium",
    browser_options: {
      "no-sandbox": nil,
      "disable-dev-shm-usage": nil,
      "disable-gpu": nil,
      "disable-software-rasterizer": nil
    }
  )
end

def browser_system_tests_enabled?
  ENV.fetch("BROWSER_SYSTEM_TESTS", "false") == "true"
end

SYSTEM_DRIVER = if browser_system_tests_enabled? && File.exist?(ENV["CHROMIUM_PATH"] || "/usr/bin/chromium")
  :paid_cuprite
else
  :rack_test
end

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
