# frozen_string_literal: true

module OperationalSupervisor
  module SanitizedPayload
    METRIC_NAMES = %w[conversion cost guardrail queue_starvation rework stage_age].freeze
    METRIC_STATUSES = %w[available unavailable].freeze
    INCLUSION_RULES = %w[enabled_projects_only].freeze

    # @spec OPERATIONAL-SUPERVISOR-001
    def sanitized_payload?(value, type:)
      case type
      when :snapshot_digest then snapshot_digest?(value)
      when :metric_provenance then metric_provenance?(value)
      when :incident_targets then incident_targets?(value)
      when :incident_evidence then incident_evidence?(value)
      when :audit_evidence then audit_evidence?(value)
      else false
      end
    end

    private

    def snapshot_digest?(value)
      exact_hash?(value, "schema_version", "metrics") && positive_integer?(value["schema_version"]) &&
        value["metrics"].is_a?(Array) && value["metrics"].all? { |metric| metric?(metric) }
    end

    def metric?(value)
      exact_hash?(value, "name", "status") && METRIC_NAMES.include?(value["name"]) && METRIC_STATUSES.include?(value["status"])
    end

    def metric_provenance?(value)
      exact_hash?(value, "window", "inclusion_rule") && value["window"].is_a?(String) && value["window"].match?(/\APT(?:\d+D)?(?:\d+H)?(?:\d+M)?(?:\d+S)?\z/) &&
        INCLUSION_RULES.include?(value["inclusion_rule"])
    end

    def incident_targets?(value)
      exact_hash?(value, "project_ids") && project_ids?(value["project_ids"])
    end

    def incident_evidence?(value)
      exact_hash?(value, "metric_names") && value["metric_names"].is_a?(Array) && value["metric_names"].all? { |name| METRIC_NAMES.include?(name) }
    end

    def audit_evidence?(value)
      exact_hash?(value, "snapshot_id") && positive_integer?(value["snapshot_id"])
    end

    def exact_hash?(value, *keys)
      value.is_a?(Hash) && value.keys.sort == keys.sort
    end

    def project_ids?(value)
      value.is_a?(Array) && value.all? { |id| positive_integer?(id) }
    end

    def positive_integer?(value)
      value.is_a?(Integer) && value.positive?
    end
  end
end
