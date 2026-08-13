# frozen_string_literal: true

require "json"
require "time"

module ClaudeCredentials
  class Secret
    Parsed = Data.define(:kind, :raw_secret, :payload) do
      def native_credentials_json?
        kind == :native_credentials_json
      end

      def long_lived_token?
        kind == :long_lived_token
      end

      def blank?
        kind == :blank
      end

      def oauth_token
        return raw_secret if long_lived_token?
        return nil unless native_credentials_json?

        payload.dig("claudeAiOauth", "accessToken") ||
          payload["accessToken"] ||
          payload["oauth_token"]
      end

      def refresh_token
        return nil unless native_credentials_json?

        payload.dig("claudeAiOauth", "refreshToken") ||
          payload["refreshToken"]
      end

      def expires_at
        raw = if native_credentials_json?
          payload.dig("claudeAiOauth", "expiresAt") ||
            payload["expiresAt"] ||
            payload["expires_at"]
        end
        return nil if raw.blank?

        Time.parse(raw.to_s)
      rescue ArgumentError
        nil
      end

      def subscription_type
        return nil unless native_credentials_json?

        payload.dig("claudeAiOauth", "subscriptionType") || payload["subscriptionType"]
      end

      def scopes
        return [] unless native_credentials_json?

        Array(payload.dig("claudeAiOauth", "scopes") || payload["scopes"]).compact
      end

      def credentials_json
        return nil unless native_credentials_json?

        JSON.generate(payload)
      end

      def refreshable?
        refresh_token.present?
      end

      def redacted_metadata
        return { "materialized" => false } if blank?

        if long_lived_token?
          return {
            "materialized" => true,
            "kind" => "long_lived_token",
            "has_refresh_token" => false,
            "has_expiry" => false
          }
        end

        {
          "materialized" => true,
          "kind" => "native_credentials_json",
          "has_refresh_token" => refreshable?,
          "has_expiry" => expires_at.present?,
          "subscription_type_present" => subscription_type.present?,
          "scopes_present" => scopes.any?
        }
      end
    end

    def self.parse(secret)
      value = secret.to_s
      return Parsed.new(kind: :blank, raw_secret: "", payload: nil) if value.blank?

      payload = JSON.parse(value)
      if payload.is_a?(Hash) && (
        payload["claudeAiOauth"].is_a?(Hash) ||
        payload["accessToken"].present? ||
        payload["oauth_token"].present?
      )
        Parsed.new(kind: :native_credentials_json, raw_secret: value, payload: payload)
      else
        Parsed.new(kind: :long_lived_token, raw_secret: value.strip, payload: nil)
      end
    rescue JSON::ParserError
      Parsed.new(kind: :long_lived_token, raw_secret: value.strip, payload: nil)
    end
  end
end
