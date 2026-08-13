# frozen_string_literal: true

begin
  require "capybara"
  require "capybara/cuprite"
rescue LoadError => e
  raise LoadError,
    "#{e.message} — capybara and cuprite are in the :test Gemfile group. " \
    "Run with RAILS_ENV=test or move them to a shared group."
end

require_relative "base"

module Screenshots
  module Driver
    class Cuprite < Base
      CAPYBARA_REMOTE_PORT = 4001

      def start_browser
        register_driver
        setup_capybara
        @session = Capybara::Session.new(driver_name, Capybara.app)
      end

      def visit(url)
        session.visit(url)
      end

      def screenshot(name:, path:)
        session.save_screenshot(path, full: true)
      end

      def authenticate(auth_config:)
        return if auth_config.strategy == "none"
        raise ArgumentError, "Cuprite only supports form auth for screenshots" unless auth_config.strategy == "form"

        session.visit(auth_config.login_path)
        auth_config.fields.each do |field, selector|
          next if field == "submit"

          session.find(selector).set(auth_config.credentials.fetch(field))
        end
        session.find(auth_config.fields.fetch("submit")).click
        wait_for_load
      end

      def wait_for_load
        session.has_no_css?("turbo-frame[busy]", wait: 5)
      end

      def current_path
        session.current_path
      end

      def quit
        session&.driver&.quit
      end

      private

      attr_reader :session

      def driver_name
        @driver_name ||= :"paid_screenshots_#{object_id}"
      end

      def register_driver
        browser_path = ENV["CHROMIUM_PATH"] || find_chrome_binary
        chrome_url = ENV["CHROME_URL"]

        Capybara.register_driver(driver_name) do |app|
          options = {
            headless: true,
            js_errors: true,
            timeout: 30,
            process_timeout: 60,
            browser_options: {
              "no-sandbox": nil,
              "disable-dev-shm-usage": nil,
              "disable-gpu": nil,
              "disable-software-rasterizer": nil,
              "window-size": "#{config.viewport.width},#{config.viewport.height}"
            }
          }

          options[:browser_path] = browser_path if browser_path
          options[:url] = chrome_url if chrome_url
          options[:base_url] = Capybara.app_host if Capybara.app_host

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
        Capybara.app = Rails.application
        Capybara.server = :puma, { Silent: true }
        remote_host = ENV["CAPYBARA_APP_HOST"]

        if ENV["CHROME_URL"].present? && remote_host.blank?
          raise "CAPYBARA_APP_HOST must be set when CHROME_URL is configured"
        end

        if remote_host.present?
          Capybara.server_host = "0.0.0.0"
          Capybara.server_port = CAPYBARA_REMOTE_PORT
          Capybara.app_host = "http://#{remote_host}:#{CAPYBARA_REMOTE_PORT}"
        else
          Capybara.server_host = "127.0.0.1"
          Capybara.app_host = nil
        end

        Capybara.default_max_wait_time = 10
      end
    end
  end
end
