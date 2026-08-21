# frozen_string_literal: true

module AgentRuns
  module EgressPolicy
    # Immutable per-run egress policy snapshot (RDR-055). Resolved once by
    # {Resolve} and persisted to +agent_runs.external_metadata["egress_policy"]+
    # before provisioning so audits can explain exactly which destinations a
    # run was allowed to reach and why, even when provisioning fails.
    #
    # Every destination hash carries provenance: +source+ (platform,
    # runner_provider, account_allowlist, project_allowlist, run_service,
    # run_preview) plus the identifier or reason that included it.
    # @spec EGRESS-POLICY-003
    class Snapshot
      PROFILES = %w[locked research open].freeze
      DEFAULT_PROFILE = "locked"

      STORAGE_KEY = "egress_policy"

      attr_reader :mode, :egress_profile, :destinations, :required_destinations, :denied_reason, :resolved_at

      def initialize(mode:, destinations:, required_destinations:, egress_profile: DEFAULT_PROFILE,
        denied_reason: nil, resolved_at: nil)
        raise ArgumentError, "egress_profile must be one of: #{PROFILES.join(', ')}" unless PROFILES.include?(egress_profile.to_s)

        @mode = mode.to_s
        @egress_profile = egress_profile.to_s
        @destinations = destinations.freeze
        @required_destinations = required_destinations.freeze
        @denied_reason = denied_reason
        @resolved_at = resolved_at
        freeze
      end

      def denied?
        denied_reason.present?
      end

      # JSON-native storage shape for +external_metadata["egress_policy"]+.
      def to_h
        {
          "mode" => mode,
          "egress_profile" => egress_profile,
          "destinations" => destinations.map { |destination| destination.transform_keys(&:to_s) },
          "required_destinations" => required_destinations.map { |destination| destination.transform_keys(&:to_s) },
          "denied_reason" => denied_reason,
          "resolved_at" => resolved_at&.iso8601
        }
      end

      # Rebuilds a snapshot from the persisted storage shape.
      def self.from_h(hash)
        resolved_at = hash["resolved_at"].present? ? Time.zone.parse(hash["resolved_at"]) : nil
        new(
          mode: hash.fetch("mode"),
          destinations: Array(hash["destinations"]),
          required_destinations: Array(hash["required_destinations"]),
          egress_profile: hash.fetch("egress_profile", DEFAULT_PROFILE),
          denied_reason: hash["denied_reason"],
          resolved_at: resolved_at
        )
      end

      # Persists the snapshot on the run before provisioning. Merges into
      # +external_metadata+ so other metadata keys survive.
      # @spec EGRESS-POLICY-006
      def persist!(agent_run)
        agent_run.update!(
          external_metadata: (agent_run.external_metadata || {}).merge(STORAGE_KEY => to_h)
        )
        self
      end

      def self.from_record(agent_run)
        raw = agent_run.external_metadata&.[](STORAGE_KEY)
        raw.is_a?(Hash) ? from_h(raw) : nil
      end
    end
  end
end
