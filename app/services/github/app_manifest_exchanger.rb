# frozen_string_literal: true

require "faraday"
require "openssl"
require "securerandom"

module Github
  # Exchanges a GitHub App manifest flow `code` for the registered App's
  # id, slug, html_url, webhook secret, and PEM private key.
  #
  # GitHub's manifest flow:
  #   https://docs.github.com/en/apps/sharing-github-apps/registering-a-github-app-from-a-manifest
  #
  # The exchange endpoint is:
  #   POST https://api.github.com/app-manifests/{code}/conversions
  #
  # Note: GitHub's manifest flow does NOT accept auth headers. The call is
  # anonymous and the `code` itself is the bearer of trust.
  class AppManifestExchanger
    class Error < StandardError; end

    Result = Struct.new(:app_id, :slug, :html_url, :private_key, :webhook_secret, keyword_init: true)

    EXCHANGE_PATH_TEMPLATE = "/app-manifests/%s/conversions".freeze
    API_BASE_URL = "https://api.github.com"

    def self.call(code:)
      new(code: code).call
    end

    def initialize(code:)
      @code = code.to_s
    end

    def call
      raise Error, "Missing GitHub manifest code" if @code.blank?

      response = connection.post(format(EXCHANGE_PATH_TEMPLATE, @code))
      raise Error, "GitHub manifest exchange failed (status #{response.status}): #{response.body}" unless response.success?

      body = JSON.parse(response.body)
      Result.new(
        app_id: body["id"],
        slug: body["slug"],
        html_url: body["html_url"],
        private_key: body["pem"],
        webhook_secret: body["webhook_secret"].presence || SecureRandom.hex(32)
      )
    rescue Faraday::Error => e
      raise Error, "GitHub manifest exchange request failed: #{e.message}"
    rescue JSON::ParserError
      raise Error, "GitHub manifest exchange returned invalid JSON"
    end

    private

    def connection
      Faraday.new(url: API_BASE_URL) do |faraday|
        faraday.options.timeout = 30
        faraday.options.open_timeout = 10
        faraday.headers["Accept"] = "application/vnd.github+json"
      end
    end
  end
end
