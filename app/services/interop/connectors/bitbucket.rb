# frozen_string_literal: true

module Interop
  module Connectors
    class Bitbucket < Base
      class << self
        def key
          "bitbucket"
        end

        def display_name
          "Bitbucket"
        end

        def description
          "Connector for ingesting Bitbucket pull request and pipeline events for coexistence workflows."
        end

        def event_types
          %w[pull_request_created pull_request_updated pull_request_merged pipeline_completed push].freeze
        end

        def normalize_event(payload)
          pr = payload.dig("pullrequest") || {}
          {
            "external_id" => pr["id"]&.to_s,
            "title" => pr["title"],
            "status" => pr.dig("state"),
            "source_branch" => pr.dig("source", "branch", "name"),
            "target_branch" => pr.dig("destination", "branch", "name"),
            "author" => pr.dig("author", "display_name"),
            "url" => pr.dig("links", "html", "href"),
            "created_at" => pr["created_on"],
            "updated_at" => pr["updated_on"]
          }.compact
        end

        def verify_signature?(raw_body, signature:, secret:, request_headers: {})
          return false if secret.blank? || signature.blank?

          expected = OpenSSL::HMAC.hexdigest("SHA256", secret, raw_body)
          ActiveSupport::SecurityUtils.secure_compare(expected, signature)
        end
      end
    end
  end
end
