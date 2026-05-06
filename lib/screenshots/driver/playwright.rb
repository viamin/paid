# frozen_string_literal: true

require "json"
require "open3"
require "uri"
require_relative "base"

module Screenshots
  module Driver
    class Playwright < Base
      def start_browser
        @stdin, @stdout, @stderr, @wait_thread = Open3.popen3(
          {
            "CHROME_URL" => ENV.fetch("CHROME_URL"),
            "SCREENSHOT_BASE_URL" => config.base_url,
            "SCREENSHOT_VIEWPORT_WIDTH" => config.viewport.width.to_s,
            "SCREENSHOT_VIEWPORT_HEIGHT" => config.viewport.height.to_s
          },
          "node",
          helper_path,
          chdir: repo_path
        )
        rpc_call("start_browser")
      rescue KeyError
        raise "CHROME_URL must be set for the Playwright screenshot driver"
      end

      def visit(url)
        rpc_call("visit", url: absolute_url(url))
      end

      def screenshot(name:, path:)
        rpc_call("screenshot", name:, path:)
      end

      def authenticate(auth_config:)
        return if auth_config.strategy == "none"

        rpc_call(
          "authenticate",
          strategy: auth_config.strategy,
          login_path: absolute_url(auth_config.login_path),
          fields: auth_config.fields,
          credentials: auth_config.credentials
        )
      end

      def wait_for_load
        rpc_call("wait_for_load")
      end

      def current_path
        response = rpc_call("current_path")
        response["current_path"]
      end

      def quit
        rpc_call("quit")
      rescue StandardError
        nil
      ensure
        [ @stdin, @stdout, @stderr ].compact.each(&:close)
        @wait_thread&.value
      end

      private

      def helper_path
        Rails.root.join("lib/screenshots/playwright_driver.mjs").to_s
      end

      def absolute_url(url)
        return url if url.to_s.match?(/\Ahttps?:\/\//)

        URI.join("#{config.base_url}/", url.to_s.delete_prefix("/")).to_s
      end

      def rpc_call(command, payload = {})
        raise "Playwright driver has not been started" unless @stdin && @stdout

        @stdin.puts(JSON.generate(payload.merge(command:)))
        @stdin.flush

        response = JSON.parse(@stdout.gets.to_s)
        raise response.fetch("error") unless response["ok"]

        response
      rescue JSON::ParserError
        raise "Playwright driver returned invalid JSON: #{@stderr.read}"
      end
    end
  end
end
