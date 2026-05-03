# frozen_string_literal: true

require "capybara"
require "capybara/cuprite"
require "fileutils"

module Screenshots
  # Captures rendered screenshots of key UI pages using Cuprite (headless Chrome).
  #
  # Intended to run in CI against a booted Rails server with seeded data so
  # reviewers can see actual rendered pages rather than mocks.
  #
  # The Chrome process is provided by a Chrome service container in CI or by
  # a locally installed Chromium on the developer machine.
  #
  # @example
  #   paths = Screenshots::Capture.call(output_dir: "tmp/screenshots")
  #   paths # => ["tmp/screenshots/sign_in.png", "tmp/screenshots/dashboard.png", ...]
  class Capture
    # Pages to capture: [slug, path, requires_auth]
    PAGES = [
      [ "sign_in", "/users/sign_in", false ],
      [ "dashboard", "/dashboard", true ],
      [ "projects", "/projects", true ],
      [ "agent_runs", "/agent_runs", true ],
      [ "prompts", "/prompts", true ],
      [ "providers", "/providers", true ],
      [ "notifications", "/notifications", true ],
      [ "service_containers", "/service_containers", true ],
      [ "integrations", "/integrations", true ]
    ].freeze

    SCREENSHOT_WIDTH = 1280
    SCREENSHOT_HEIGHT = 900

    def self.call(output_dir: "tmp/screenshots")
      new(output_dir: output_dir).call
    end

    def initialize(output_dir:)
      @output_dir = output_dir
    end

    def call
      FileUtils.mkdir_p(@output_dir)
      register_driver
      setup_capybara

      captured = []
      session = Capybara::Session.new(:paid_screenshots)

      auth_user = ensure_seed_user!
      sign_in(session, auth_user) if PAGES.any? { |_, _, auth| auth }

      PAGES.each do |slug, path, requires_auth|
        file_path = File.join(@output_dir, "#{slug}.png")
        begin
          session.visit(path)
          session.save_screenshot(file_path, full: true)
          captured << file_path
          puts "  Captured: #{slug} -> #{file_path}"
        rescue StandardError => e
          warn "  Failed to capture #{slug} (#{path}): #{e.message}"
        end
      end

      session.driver.quit
      captured
    end

    private

    def register_driver
      browser_path = ENV["CHROMIUM_PATH"] || find_chrome_binary
      chrome_url = ENV["CHROME_URL"]

      Capybara.register_driver(:paid_screenshots) do |app|
        options = {
          headless: true,
          js_errors: false,
          timeout: 30,
          process_timeout: 60,
          browser_options: {
            "no-sandbox": nil,
            "disable-dev-shm-usage": nil,
            "disable-gpu": nil,
            "disable-software-rasterizer": nil,
            "window-size": "#{SCREENSHOT_WIDTH},#{SCREENSHOT_HEIGHT}"
          }
        }

        options[:browser_path] = browser_path if browser_path
        options[:url] = chrome_url if chrome_url

        Capybara::Cuprite::Driver.new(app, **options)
      end
    end

    def find_chrome_binary
      %w[
        /usr/bin/google-chrome
        /usr/bin/chromium
        /usr/bin/chromium-browser
      ].find { |path| File.exist?(path) }
    end

    def setup_capybara
      Capybara.server = :puma, { Silent: true }
      Capybara.server_host = "127.0.0.1"
      Capybara.default_max_wait_time = 10
    end

    def ensure_seed_user!
      account = Account.first_or_create!(
        name: "Screenshot Account",
        slug: "screenshot-account"
      )

      user = User.find_by(email: "screenshot@example.com")
      unless user
        user = User.create!(
          email: "screenshot@example.com",
          password: "screenshot-password-123",
          password_confirmation: "screenshot-password-123"
        )
      end

      unless user.account_memberships.exists?(account: account)
        user.account_memberships.create!(account: account, role: :owner)
      end

      user
    end

    def sign_in(session, user)
      session.visit("/users/sign_in")
      session.fill_in "Email", with: user.email
      session.fill_in "Password", with: "screenshot-password-123"
      session.click_button "Sign in"
    end
  end
end
