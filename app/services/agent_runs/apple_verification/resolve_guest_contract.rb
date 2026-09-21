# frozen_string_literal: true

module AgentRuns
  module AppleVerification
    # Resolves and persists the run's egress snapshot with a forced
    # proxy-restricted networking intent, then produces the guest's
    # declarative {GuestContract} (RDR-068).
    #
    # Contract production is gated on the project's +apple_verification_workers+
    # rollout flag: until an operator has enabled the flag (after the worker
    # profile, proxy, DNS, and isolation smoke tests pass), Paid must not
    # admit an Apple verification guest at all, so no contract is produced.
    #
    # The production caller is {AppleVerification::ExecuteGuestJob} (a sibling
    # top-level namespace, +AppleVerification+, not +AgentRuns+). That job is
    # the guest-admission boundary: it calls this resolver to install the Paid
    # network contract before dispatching a manifest to the authenticated guest
    # executor, so no guest can start with an implicit or caller-controlled
    # network policy. This class lives under +AgentRuns::AppleVerification+
    # (rather than next to its caller) because it shares +GuestContract+,
    # +ValidateGuestRequest+, +GuestNetworkRequest+, and +NetworkPolicyError+
    # with the rest of the per-run egress policy surface; the cluster keeps
    # the network-policy code grouped with the existing +AgentRuns::EgressPolicy+
    # family instead of scattering it across both namespaces.
    # @spec APPLE-NETWORK-001
    class ResolveGuestContract
      # Raised when the project has not enabled +apple_verification_workers+.
      # Distinct from {NetworkPolicyError}: this is a rollout gate, not a
      # request-time policy denial.
      class WorkersDisabledError < StandardError; end

      FORCED_EGRESS_PROFILE = :locked

      def self.call(agent_run:)
        new(agent_run: agent_run).call
      end

      def initialize(agent_run:)
        @agent_run = agent_run
      end

      def call
        unless FeatureFlags.enabled?(:apple_verification_workers, project: agent_run.project)
          raise WorkersDisabledError, "apple_verification_workers is disabled for project #{agent_run.project_id}"
        end

        GuestContract.from_snapshot(snapshot)
      end

      private

      attr_reader :agent_run

      def snapshot
        AgentRuns::EgressPolicy::Resolve.resolve_and_persist!(agent_run, networking_policy: forced_policy)
      end

      def forced_policy
        ExecutionRunners::NetworkingPolicy.proxy_only(egress_profile: FORCED_EGRESS_PROFILE)
      end
    end
  end
end
