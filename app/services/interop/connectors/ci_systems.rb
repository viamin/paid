# frozen_string_literal: true

module Interop
  module Connectors
    class CiSystems < Base
      class << self
        def key
          "ci_systems"
        end

        def display_name
          "CI Systems"
        end

        def description
          "Connector for ingesting CI pipeline events and outcomes for external execution comparison."
        end

        def event_types
          %w[pipeline_started pipeline_completed pipeline_failed job_completed workflow_completed].freeze
        end

        def normalize_event(payload)
          {
            "external_id" => payload["pipeline_id"] || payload["run_id"],
            "status" => payload["status"],
            "branch" => payload["branch"],
            "commit_sha" => payload["commit_sha"],
            "duration_seconds" => payload["duration_seconds"],
            "ci_system" => payload["ci_system"],
            "url" => payload["url"],
            "started_at" => payload["started_at"],
            "finished_at" => payload["finished_at"],
            "test_results" => payload["test_results"]
          }.compact
        end

        def verify_signature?(payload, signature:, secret:)
          return false if secret.blank? || signature.blank?

          expected = OpenSSL::HMAC.hexdigest("SHA256", secret, payload.to_json)
          ActiveSupport::SecurityUtils.secure_compare(expected, signature)
        end
      end
    end
  end
end
