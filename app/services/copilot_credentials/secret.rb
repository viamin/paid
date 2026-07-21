# frozen_string_literal: true

require "json"
require "time"

module CopilotCredentials
  # Parses an encrypted Copilot `RunnerCredential#token` into a normalized
  # GitHub Copilot OAuth session and materializes the minimal native CLI config
  # the Copilot CLI needs inside the container (RDR-041 / #2964).
  #
  # The stored secret is the contents of the Copilot CLI's `~/.copilot/config.json`,
  # whose OAuth token may live under any of the keys the CLI has used across
  # versions (`oauth_token`, `oauthToken`, `token`, or nested under `auth`).
  # The materializer regenerates a minimal config carrying only the OAuth token
  # plus non-secret lifecycle hints, so a managed credential can carry a run to
  # a remote Docker backend without a host bind mount.
  #
  # Mirrors the contract of `ClaudeCredentials::Secret`: parsing is pure and
  # side-effect free, native file generation lives on the parsed result, and the
  # `redacted_metadata` helper exposes only non-secret context so the telemetry
  # recorder never persists tokens.
  class Secret
    TOKEN_KEYS = %w[oauth_token oauthToken token].freeze

    Parsed = Data.define(:kind, :raw_secret, :payload) do
      def blank?
        kind == :blank
      end

      def copilot_config?
        kind == :copilot_config
      end

      def oauth_token
        return nil unless copilot_config?

        token_entry || payload.dig("auth", "token")
      end

      def refresh_token
        return nil unless copilot_config?

        payload["refresh_token"] || payload["refreshToken"] || payload.dig("auth", "refresh_token")
      end

      def expires_at
        return nil unless copilot_config?

        raw = payload["expires_at"] || payload["expiresAt"] || payload.dig("auth", "expires_at")
        return nil if raw.blank?

        Time.parse(raw.to_s)
      rescue ArgumentError
        nil
      end

      # Materializes the minimal native `config.json` the Copilot CLI reads for
      # authentication. Drops unrelated host-only fields so the container gets
      # only what the CLI needs.
      def config_json
        return nil unless copilot_config?

        JSON.generate(native_payload)
      end

      # Non-secret summary safe to persist in runner auth telemetry. Never
      # includes the OAuth token, refresh token, or any bearer material.
      def redacted_metadata
        return { "materialized" => false } unless copilot_config?

        {
          "materialized" => true,
          "has_refresh_token" => refresh_token.present?,
          "has_expiry" => expires_at.present?
        }
      end

      private

      def token_entry
        TOKEN_KEYS.each do |key|
          return payload[key] if payload[key].present?
        end
        nil
      end

      def native_payload
        payload = { "oauth_token" => oauth_token }
        payload["refresh_token"] = refresh_token if refresh_token.present?
        expires = expires_at
        payload["expires_at"] = expires.iso8601 if expires
        payload
      end
    end

    def self.parse(secret)
      value = secret.to_s
      return Parsed.new(kind: :blank, raw_secret: "", payload: nil) if value.blank?

      payload = JSON.parse(value)
      if copilot_config_payload?(payload)
        Parsed.new(kind: :copilot_config, raw_secret: value, payload: payload)
      else
        Parsed.new(kind: :blank, raw_secret: "", payload: nil)
      end
    rescue JSON::ParserError
      Parsed.new(kind: :blank, raw_secret: "", payload: nil)
    end

    def self.copilot_config_payload?(payload)
      return false unless payload.is_a?(Hash)

      TOKEN_KEYS.any? { |key| payload[key].present? } ||
        payload.dig("auth", "token").present?
    end
  end
end
