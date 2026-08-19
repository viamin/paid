# frozen_string_literal: true

module AgentRuns
  module EgressPolicy
    # Resolves the per-run egress policy snapshot (RDR-055).
    #
    # Deterministic merge order:
    #   1. platform-required destinations (secrets proxy, egress gateway)
    #   2. GitHub destinations (repo checkout, PR operations)
    #   3. runner/provider-required destinations — only when the network mode
    #      requires direct provider egress (subscription_auth / direct_outbound)
    #   4. enabled account-wide allowlist entries
    #   5. enabled project allowlist entries (extend, never remove, required)
    #   6. run-local service and preview destinations
    #
    # Unsafe entries are defensively re-validated and rejected before any
    # container starts: the resolved snapshot records a +denied_reason+ and
    # {resolve_and_persist!} raises {DeniedPolicyError} after persisting the
    # denied snapshot so the rejection stays auditable.
    # @spec EGRESS-POLICY-003
    # @spec EGRESS-POLICY-004
    # @spec EGRESS-POLICY-005
    class Resolve
      class DeniedPolicyError < StandardError; end

      DIRECT_PROVIDER_MODES = %w[subscription_auth direct_outbound].freeze

      def self.call(agent_run:, networking_policy: nil, egress_profile: Snapshot::DEFAULT_PROFILE,
        preview_destination: nil, platform_destinations: nil)
        new(
          agent_run: agent_run,
          networking_policy: networking_policy,
          egress_profile: egress_profile,
          preview_destination: preview_destination,
          platform_destinations: platform_destinations
        ).call
      end

      # Resolves, persists the snapshot on the run (+before+ provisioning),
      # and fails closed by raising when the policy was denied.
      # @spec EGRESS-POLICY-005
      # @spec EGRESS-POLICY-006
      def self.resolve_and_persist!(agent_run, **options)
        snapshot = call(agent_run: agent_run, **options)
        snapshot.persist!(agent_run)
        log_resolution(agent_run, snapshot)
        raise DeniedPolicyError, snapshot.denied_reason if snapshot.denied?

        snapshot
      end

      def initialize(agent_run:, networking_policy:, egress_profile:, preview_destination:, platform_destinations:)
        @agent_run = agent_run
        @networking_policy = networking_policy
        @egress_profile = egress_profile
        @preview_destination = preview_destination
        @platform_destinations = platform_destinations
      end

      def call
        Snapshot.new(
          mode: mode,
          egress_profile: effective_profile,
          destinations: merged_destinations,
          required_destinations: required_destinations,
          denied_reason: denied_reason,
          resolved_at: Time.current
        )
      end

      private

      attr_reader :agent_run, :networking_policy, :egress_profile, :preview_destination, :platform_destinations

      def mode
        policy.mode.to_s
      end

      def effective_profile
        egress_profile.to_s.presence || Snapshot::DEFAULT_PROFILE
      end

      def policy
        @policy ||= networking_policy || Containers::Provision.networking_policy_for(
          agent_run: agent_run, project: agent_run.project
        )
      end

      def required_destinations
        @required_destinations ||=
          (platform_destinations || RequiredDestinations.platform) +
          RequiredDestinations.github +
          provider_destinations
      end

      def provider_destinations
        return [] unless DIRECT_PROVIDER_MODES.include?(mode)

        RequiredDestinations.provider(runner: agent_run.runner, agent_type: agent_run.agent_type)
      end

      def merged_destinations
        dedupe(required_destinations + allowlist_destinations + run_local_destinations)
      end

      def allowlist_destinations
        safe_entries.map { |entry| entry_destination(entry) }
      end

      # Excludes unsafe entries (see {entry_unsafe_reason}) and entries whose
      # host is already required. A tenant entry can otherwise carry a
      # different (or absent, meaning "any") port than the required
      # destination, dodging the host+port dedupe key in {dedupe} and
      # widening a required destination's port restriction. Dropping the
      # entry here — rather than merging it — keeps EGRESS-POLICY-004 true:
      # a required destination can never be shadowed or extended by tenant
      # configuration.
      # @spec EGRESS-POLICY-004
      def safe_entries
        (account_entries + project_entries).select do |entry|
          entry_unsafe_reason(entry).nil? && !required_host?(entry)
        end
      end

      def required_host?(entry)
        required_destination_hosts.include?(entry.host_pattern.to_s.strip.downcase)
      end

      def required_destination_hosts
        @required_destination_hosts ||= required_destinations.map { |destination| destination["host"].to_s.downcase }
      end

      def entry_destination(entry)
        {
          "host" => entry.host_pattern,
          "port" => entry.port,
          "scheme" => entry.scheme,
          "source" => entry.project_id ? "project_allowlist" : "account_allowlist",
          "entry_id" => entry.id,
          "reason" => entry.reason
        }.compact
      end

      def account_entries
        @account_entries ||= load_entries(scope: :account)
      end

      def project_entries
        @project_entries ||= load_entries(scope: :project)
      end

      def load_entries(scope:)
        relation = EgressAllowlistEntry.enabled.where(account: agent_run.project&.account)
        relation = scope == :account ? relation.account_wide : relation.for_project(agent_run.project)
        relation.order(:id).to_a
      end

      # Safe entries become destinations with provenance; unsafe entries are
      # excluded and recorded so resolution fails closed instead of widening
      # the policy.
      # @spec EGRESS-POLICY-005
      def denied_reason
        return nil if unsafe_entries.empty?

        "unsafe egress allowlist entries rejected before container start: " \
          "#{unsafe_entries.map { |entry| entry_rejection(entry) }.join('; ')}"
      end

      def unsafe_entries
        (account_entries + project_entries).reject { |entry| entry_unsafe_reason(entry).nil? }
      end

      def entry_rejection(entry)
        "#{scope_label(entry)} entry #{entry.id} (#{entry.host_pattern}): #{entry_unsafe_reason(entry)}"
      end

      def scope_label(entry)
        entry.project_id ? "project" : "account"
      end

      def entry_unsafe_reason(entry)
        reason = HostPattern.invalid_reason(entry.host_pattern)
        return reason if reason
        return "port must be between 1 and 65535" if entry.port.present? && !entry.port.to_i.between?(1, 65_535)
        return "scheme must be http or https" if entry.scheme.present? && %w[http https].exclude?(entry.scheme.to_s)

        nil
      end

      def run_local_destinations
        service_destinations + preview_destinations
      end

      def service_destinations
        service_containers.map do |service|
          {
            "host" => service.name,
            "port" => service.port,
            "source" => "run_service",
            "service_container_id" => service.id
          }
        end
      end

      def service_containers
        ids = Array(agent_run.service_container_ids)
        return [] if ids.blank?

        ServiceContainer.where(id: ids, status: "running").order(:id)
      end

      def preview_destinations
        return [] if preview_destination.blank?

        [
          {
            "host" => preview_destination.fetch(:host),
            "port" => preview_destination.fetch(:port),
            "source" => "run_preview"
          }
        ]
      end

      # First occurrence wins, so the merge order defines precedence:
      # required destinations can never be shadowed or removed by tenant
      # entries, and an account entry outranks a duplicate project entry.
      def dedupe(destinations)
        seen = {}
        destinations.each_with_object([]) do |destination, result|
          key = [ destination["host"], destination["port"] ]
          next if seen.key?(key)

          seen[key] = true
          result << destination
        end
      end

      def self.log_resolution(agent_run, snapshot)
        Rails.logger.public_send(snapshot.denied? ? :error : :info,
          message: "container_manager.egress_policy.#{snapshot.denied? ? 'denied' : 'resolved'}",
          agent_run_id: agent_run.id,
          mode: snapshot.mode,
          egress_profile: snapshot.egress_profile,
          destination_count: snapshot.destinations.length
        )
      end
    end
  end
end
