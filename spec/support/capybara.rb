# frozen_string_literal: true

require "capybara/cuprite"

Capybara.register_driver(:cuprite) do |app|
  Capybara::Cuprite::Driver.new(app,
    headless: true,
    js_errors: true,
    timeout: 10,
    process_timeout: 30,
    browser_options: {
      "no-sandbox": nil,
      "disable-dev-shm-usage": nil
    }
  )
end

Capybara.default_driver = :cuprite
Capybara.javascript_driver = :cuprite
