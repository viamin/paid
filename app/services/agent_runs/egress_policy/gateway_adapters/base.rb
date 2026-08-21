# frozen_string_literal: true

module AgentRuns
  module EgressPolicy
    module GatewayAdapters
      # Abstract gateway adapter contract. Concrete adapters translate a
      # per-run egress policy snapshot into a platform-specific egress
      # gateway and translate gateway denials into structured audit events.
      #
      # The contract is intentionally minimal: every production runtime
      # that can enforce the egress policy must be able to express it in
      # these four operations. A runtime that cannot is rejected by
      # {ExecutionRunners::Base.gateway_adapter}, which returns nil and
      # the runner surfaces as a fail-closed {ProvisionError} before any
      # provisioning work begins.
      # @spec EGRESS-POLICY-007
      class Base
        # Materializes the gateway on the host backing +backend+ so the
        # container can route its outbound HTTP(S) through it.
        # Implementations are required to fail closed: if the gateway
        # cannot be brought up, the call MUST raise {Gateway::UnavailableError}
        # so the runner aborts provisioning rather than starting a
        # container with no enforcement.
        #
        # @param agent_run [AgentRun, nil] the run that owns this gateway (audit correlation)
        # @param snapshot [Snapshot] the resolved egress policy snapshot
        # @param backend [Object] the backend/runner descriptor the gateway will live on
        # @return [void]
        # @raise [Gateway::UnavailableError] when the gateway cannot be set up
        def ensure!(agent_run:, snapshot:, backend:)
          raise NotImplementedError, "#{self.class} must implement ##{__method__}"
        end

        # Returns the +host:port+ string the runner should allow through
        # the in-container firewall so the agent container can reach the
        # gateway. The host component must be resolvable from the agent
        # container (Docker network alias, Kubernetes service DNS, or a
        # platform-specific equivalent).
        #
        # @param snapshot [Snapshot] the resolved egress policy snapshot
        # @param backend [Object] backend descriptor (for backend-scoped hostnames)
        # @return [String] +host:port+ form
        def gateway_url(snapshot:, backend:)
          raise NotImplementedError, "#{self.class} must implement ##{__method__}"
        end

        # Returns the gateway's per-run allowlist, expressed in the
        # canonical +{host:, port:}+ shape used by {NetworkingPolicy}.
        # The runner uses this to populate iptables/NetworkPolicy rules
        # that bypass the gateway for direct platform peers, and so the
        # gateway's denials carry the same shape as the snapshot.
        #
        # @param snapshot [Snapshot] the resolved egress policy snapshot
        # @return [Array<Hash>] destinations the gateway will allow
        def allowlist_for(snapshot:)
          raise NotImplementedError, "#{self.class} must implement ##{__method__}"
        end

        # Whether this adapter can enforce the policy on the given backend.
        # Returns +false+ when the platform lacks the primitives (CNI
        # without NetworkPolicy, provider firewall that does not accept
        # per-host filters, etc). The runner reports this as a
        # fail-closed rejection for production restricted runs.
        #
        # @param snapshot [Snapshot, nil]
        # @param backend [Object]
        # @return [Boolean]
        def capable?(snapshot: nil, backend: nil)
          true
        end
      end
    end
  end
end
