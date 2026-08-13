# frozen_string_literal: true

module Interop
  module Connectors
    class GitLab < Base
      class << self
        def key
          "gitlab"
        end

        def display_name
          "GitLab"
        end

        def description
          "Connector for ingesting GitLab merge request and pipeline events for coexistence workflows."
        end

        def event_types
          %w[merge_request_opened merge_request_updated merge_request_merged pipeline_completed push].freeze
        end

        def normalize_event(payload)
          attrs = payload.dig("object_attributes") || {}
          {
            "external_id" => attrs["iid"]&.to_s,
            "title" => attrs["title"],
            "status" => attrs["state"],
            "source_branch" => attrs["source_branch"],
            "target_branch" => attrs["target_branch"],
            "author" => payload.dig("user", "username"),
            "url" => attrs["url"],
            "pipeline_status" => attrs["status"],
            "created_at" => attrs["created_at"],
            "updated_at" => attrs["updated_at"]
          }.compact
        end

        def verify_signature?(raw_body, signature:, secret:, request_headers: {})
          return false if secret.blank? || signature.blank?

          if header_value(request_headers, "webhook-signature").present?
            verify_signing_token(raw_body, signature:, secret:, request_headers:)
          else
            ActiveSupport::SecurityUtils.secure_compare(secret, signature)
          end
        end

        private

        def verify_signing_token(raw_body, signature:, secret:, request_headers:)
          webhook_id = header_value(request_headers, "webhook-id").to_s
          timestamp = header_value(request_headers, "webhook-timestamp").to_s
          return false if webhook_id.blank? || timestamp.blank?
          return false unless recent_unix_timestamp?(timestamp)

          raw_key = Base64.strict_decode64(secret.delete_prefix("whsec_"))
          expected = "v1,#{Base64.strict_encode64(OpenSSL::HMAC.digest("SHA256", raw_key, "#{webhook_id}.#{timestamp}.#{raw_body}"))}"

          signature.split(" ").any? do |candidate|
            ActiveSupport::SecurityUtils.secure_compare(expected, candidate)
          end
        rescue ArgumentError
          false
        end
      end
    end
  end
end
