# frozen_string_literal: true

require "json"
require "time"

module GeminiCredentials
  # Parses an encrypted Gemini `RunnerCredential#token` into a normalized OAuth
  # session and materializes the minimal native CLI config the Gemini CLI needs
  # inside the container (RDR-041 / #2964).
  #
  # The stored secret is the contents of the Gemini CLI's `~/.gemini/oauth_creds.json`
  # (a Google OAuth access/refresh token payload). The materializer regenerates
  # only the fields the CLI reads for authentication, so a managed credential
  # can carry a run to a remote Docker backend without a host bind mount.
  #
  # Mirrors the contract of `ClaudeCredentials::Secret`: parsing is pure and
  # side-effect free, native file generation lives on the parsed result, and the
  # `redacted_metadata` helper exposes only non-secret context so the telemetry
  # recorder never persists tokens.
  class Secret
    # Minimal shape the Gemini CLI reads from ~/.gemini/oauth_creds.json.
    NATIVE_KEYS = %w[access_token refresh_token scope token_type expiry_date].freeze

    Parsed = Data.define(:kind, :raw_secret, :payload) do
      def blank?
        kind == :blank
      end

      def oauth_credentials?
        kind == :oauth_credentials
      end

      def access_token
        return nil unless oauth_credentials?

        payload["access_token"] || payload["accessToken"]
      end

      def refresh_token
        return nil unless oauth_credentials?

        payload["refresh_token"] || payload["refreshToken"]
      end

      def scope
        return nil unless oauth_credentials?

        payload["scope"]
      end

      def token_type
        return nil unless oauth_credentials?

        payload["token_type"] || payload["tokenType"] || "Bearer"
      end

      # Google OAuth stores expiry as epoch milliseconds.
      def expiry_date_ms
        return nil unless oauth_credentials?

        raw = payload["expiry_date"] || payload["expiryDate"]
        raw.to_i if raw.present?
      end

      def expires_at
        ms = expiry_date_ms
        return nil unless ms&.positive?

        Time.at(ms / 1000.0, in: "UTC")
      rescue ArgumentError
        nil
      end

      # Materializes the minimal native `oauth_creds.json` the Gemini CLI
      # authenticates from. Drops unrelated host-only fields so the container
      # gets only what the CLI needs.
      def oauth_creds_json
        return nil unless oauth_credentials?

        JSON.generate(native_payload)
      end

      # Non-secret summary safe to persist in runner auth telemetry. Never
      # includes the access token, refresh token, or any bearer material.
      def redacted_metadata
        return { "materialized" => false } unless oauth_credentials?

        {
          "materialized" => true,
          "has_refresh_token" => refresh_token.present?,
          "has_expiry" => expiry_date_ms.present?,
          "scope_present" => scope.present?
        }
      end

      private

      def native_payload
        {
          "access_token" => access_token,
          "refresh_token" => refresh_token,
          "scope" => scope,
          "token_type" => token_type,
          "expiry_date" => expiry_date_ms
        }.compact
      end
    end

    def self.parse(secret)
      value = secret.to_s
      return Parsed.new(kind: :blank, raw_secret: "", payload: nil) if value.blank?

      payload = JSON.parse(value)
      if oauth_credentials_payload?(payload)
        Parsed.new(kind: :oauth_credentials, raw_secret: value, payload: payload)
      else
        Parsed.new(kind: :blank, raw_secret: "", payload: nil)
      end
    rescue JSON::ParserError
      Parsed.new(kind: :blank, raw_secret: "", payload: nil)
    end

    def self.oauth_credentials_payload?(payload)
      return false unless payload.is_a?(Hash)

      payload["access_token"].present? ||
        payload["accessToken"].present? ||
        payload["refresh_token"].present? ||
        payload["refreshToken"].present?
    end
  end
end
