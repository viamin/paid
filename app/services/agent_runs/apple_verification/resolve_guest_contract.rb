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
    # Deliberately has no caller outside this segment's own specs. Guest
    # provisioning itself (the Tart/Softnet host lifecycle, #3933) is not
    # implemented anywhere in Paid yet, so there is no real admission path to
    # wire this into. A prior revision of this work added stub +GuestLauncher+/
    # +TartProvider+/+HostService+ objects to call this from, but those only
    # simulated provisioning against no real guest; that wiring was removed
    # (see git history, "defer unenforceable guest policy") because a fake
    # enforcement call site is worse than none — it would read as "enforced"
    # in review while actually enforcing nothing. This class exists to be
    # fully built, tested, and ready so the #3933 host-service integration has
    # only to call it, not design it.
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
