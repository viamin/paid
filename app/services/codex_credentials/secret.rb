# frozen_string_literal: true

require "base64"
require "json"
require "time"

module CodexCredentials
  # Parses an encrypted Codex `RunnerCredential#token` into a normalized OpenAI
  # OAuth session and materializes the minimal native `auth.json` the Codex CLI
  # authenticates from (RDR-041 / #2962).
  #
  # The stored secret mirrors the Codex CLI's `~/.codex/auth.json`, whose OAuth
  # state nests under `tokens` (access token, refresh token, id token, account
  # id) alongside a top-level `OPENAI_API_KEY` and a `last_refresh` timestamp.
  # The materializer regenerates only the fields the CLI reads for
  # authentication, so a managed credential can carry a run to a Docker backend
  # without a host bind mount of `auth.json`.
  #
  # Mirrors the contract of `ClaudeCredentials::Secret` / `GeminiCredentials::Secret`:
  # parsing is pure and side-effect free, native file generation lives on the
  # parsed result, and `redacted_metadata` exposes only non-secret context so the
  # telemetry recorder never persists tokens.
  class Secret
    AUTH_PATH = "/home/agent/.codex/auth.json"

    Parsed = Data.define(:kind, :raw_secret, :payload) do
      def blank?
        kind == :blank
      end

      def codex_auth?
        kind == :codex_auth
      end

      def tokens
        return nil unless codex_auth?

        payload["tokens"].is_a?(Hash) ? payload["tokens"] : {}
      end

      def access_token
        return nil unless codex_auth?

        tokens["access_token"] || tokens["accessToken"]
      end

      def refresh_token
        return nil unless codex_auth?

        tokens["refresh_token"] || tokens["refreshToken"]
      end

      def id_token
        return nil unless codex_auth?

        tokens["id_token"] || tokens["idToken"]
      end

      def account_id
        return nil unless codex_auth?

        tokens["account_id"] || tokens["accountId"]
      end

      def openai_api_key
        return nil unless codex_auth?

        payload["OPENAI_API_KEY"]
      end

      def last_refresh
        return nil unless codex_auth?

        raw = payload["last_refresh"]
        return nil if raw.blank?

        Time.parse(raw.to_s)
      rescue ArgumentError
        nil
      end

      # Access tokens issued for Codex are JWTs whose `exp` claim records the
      # expiry. Falls back to an explicit `expires_at` / `expiresAt` field when
      # the token is opaque or unparseable. Returns nil when expiry is unknown.
      def expires_at
        return nil unless codex_auth?

        from_exp = jwt_expiry(access_token)
        return from_exp if from_exp

        raw = payload["expires_at"] || payload["expiresAt"] || tokens["expires_at"]
        return nil if raw.blank?

        Time.parse(raw.to_s)
      rescue ArgumentError
        nil
      end

      def refreshable?
        refresh_token.present?
      end

      # Materializes the minimal native `auth.json` the Codex CLI authenticates
      # from. Drops unrelated host-only fields so the container gets only what
      # the CLI needs.
      def auth_json
        return nil unless codex_auth?

        JSON.generate(native_payload)
      end

      # Non-secret summary safe to persist in runner auth telemetry. Never
      # includes the access token, refresh token, id token, or account id.
      def redacted_metadata
        return { "materialized" => false } unless codex_auth?

        {
          "materialized" => true,
          "has_refresh_token" => refresh_token.present?,
          "has_expiry" => expires_at.present?,
          "has_account_id" => account_id.present?,
          "has_openai_api_key" => openai_api_key.present?
        }
      end

      private

      def jwt_expiry(token)
        return nil if token.blank?

        payload_part = token.to_s.split(".")[1]
        return nil if payload_part.blank?

        decoded = jwt_base64_decode(payload_part)
        return nil unless decoded

        exp = JSON.parse(decoded)["exp"]
        return nil unless exp.is_a?(Numeric) && exp.positive?

        Time.at(exp.to_i, in: "UTC")
      rescue ArgumentError, JSON::ParserError
        nil
      end

      def jwt_base64_decode(segment)
        padded = segment + ("=" * ((4 - segment.length % 4) % 4))
        Base64.urlsafe_decode64(padded)
      rescue ArgumentError
        nil
      end

      def native_payload
        tokens_payload = {
          "id_token" => id_token,
          "access_token" => access_token,
          "refresh_token" => refresh_token,
          "account_id" => account_id
        }.compact
        payload_out = { "OPENAI_API_KEY" => openai_api_key.presence }
        payload_out["tokens"] = tokens_payload if tokens_payload.any?
        refreshed = last_refresh || Time.now
        payload_out["last_refresh"] = refreshed.utc.iso8601
        payload_out
      end
    end

    # Builds the canonical Codex `auth.json` payload from raw OAuth tokens
    # captured during the device-code Connect Codex flow (RDR-041 / #2962). The
    # token map mirrors {CodexLoginSessions::OAuthClient}'s success payload
    # (id_token, access_token, refresh_token, account_id). Returns nil when the
    # tokens lack both an access and refresh token, since neither the CLI nor the
    # refresh path can use such a session.
    def self.build(tokens)
      return nil unless tokens.is_a?(Hash)

      normalized = {
        "id_token" => tokens["id_token"],
        "access_token" => tokens["access_token"],
        "refresh_token" => tokens["refresh_token"],
        "account_id" => tokens["account_id"]
      }
      expires_at = tokens["expires_at"] || tokens["expiresAt"]
      return nil if normalized["access_token"].blank? && normalized["refresh_token"].blank?

      payload = {
        "OPENAI_API_KEY" => nil,
        "tokens" => normalized.compact,
        "last_refresh" => Time.now.utc.iso8601
      }
      payload["expires_at"] = expires_at if expires_at.present?
      JSON.generate(payload)
    end

    def self.parse(secret)
      value = secret.to_s
      return Parsed.new(kind: :blank, raw_secret: "", payload: nil) if value.blank?

      payload = JSON.parse(value)
      if codex_auth_payload?(payload)
        Parsed.new(kind: :codex_auth, raw_secret: value, payload: payload)
      else
        Parsed.new(kind: :blank, raw_secret: "", payload: nil)
      end
    rescue JSON::ParserError
      Parsed.new(kind: :blank, raw_secret: "", payload: nil)
    end

    def self.codex_auth_payload?(payload)
      return false unless payload.is_a?(Hash)

      tokens = payload["tokens"]
      return false unless tokens.is_a?(Hash)

      tokens["access_token"].present? ||
        tokens["accessToken"].present? ||
        tokens["refresh_token"].present? ||
        tokens["refreshToken"].present?
    end
  end
end
