# frozen_string_literal: true

require "json"
require "time"

module OpencodeCredentials
  # Parses OpenCode's native auth.json and converts the stored OpenAI OAuth row
  # back into Paid's canonical Codex auth payload when harvesting container
  # rotations. OpenCode stores auth as a top-level provider map keyed by
  # provider id (`openai` for Codex-backed OAuth).
  class Secret
    AUTH_PATH = "/home/agent/.local/share/opencode/auth.json"
    PROVIDER_KEY = "openai"

    Parsed = Data.define(:kind, :raw_secret, :payload) do
      def opencode_auth?
        kind == :opencode_auth
      end

      def oauth_entry
        return {} unless opencode_auth?

        payload[PROVIDER_KEY].is_a?(Hash) ? payload[PROVIDER_KEY] : {}
      end

      def access_token
        oauth_entry["access"]
      end

      def refresh_token
        oauth_entry["refresh"]
      end

      def account_id
        oauth_entry["accountId"] || oauth_entry["account_id"]
      end

      def expires_at
        raw = oauth_entry["expires"]
        return nil unless raw.is_a?(Numeric)

        Time.at(raw.to_f / 1000, in: "UTC")
      end

      def codex_auth_json
        return nil unless opencode_auth?

        CodexCredentials::Secret.build(
          "access_token" => access_token,
          "refresh_token" => refresh_token,
          "account_id" => account_id,
          "expires_at" => expires_at&.utc&.iso8601
        )
      end
    end

    def self.parse(secret)
      value = secret.to_s
      return Parsed.new(kind: :blank, raw_secret: "", payload: nil) if value.blank?

      payload = JSON.parse(value)
      if opencode_auth_payload?(payload)
        Parsed.new(kind: :opencode_auth, raw_secret: value, payload: payload)
      else
        Parsed.new(kind: :blank, raw_secret: "", payload: nil)
      end
    rescue JSON::ParserError
      Parsed.new(kind: :blank, raw_secret: "", payload: nil)
    end

    def self.opencode_auth_payload?(payload)
      return false unless payload.is_a?(Hash)

      oauth = payload[PROVIDER_KEY]
      return false unless oauth.is_a?(Hash) && oauth["type"] == "oauth"

      oauth["access"].present? || oauth["refresh"].present?
    end
  end
end
