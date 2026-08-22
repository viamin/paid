# frozen_string_literal: true

module AgentRuns
  module EgressPolicy
    # Per-host egress gateway abstraction (RDR-055 step 5).
    #
    # Docker restricted runs reach only Paid-local destinations (secrets
    # proxy, GitHub proxy, service-container peers, preview tunnel) plus
    # the egress gateway itself. All other outbound HTTP(S) traffic must
    # go through the gateway, which filters CONNECT/HTTP requests by host
    # against the per-run allowlist (snapshot destinations) and logs denied
    # attempts as {EgressSecurityEvent} records with `agent_run_id`, host,
    # port, and matched/failed rule context.
    #
    # Adapters translate the abstract contract into a concrete platform
    # (Docker sidecar, Kubernetes service, managed-machine sidecar).
    # Runners resolve the right adapter via {ExecutionRunners::Base.gateway_adapter}
    # and pass it to {Gateway.new}; the runner translation layer is the
    # only caller of +#ensure!+, +#gateway_url+, +#allowlist_for+, and
    # +#record_denial!+.
    # @spec EGRESS-POLICY-007
    class Gateway
      # Raised when the gateway cannot be brought up on the host. The
      # runner treats this as a fail-closed condition in production: the
      # container is not started and the run surfaces a ProvisionError so
      # the run audit trail records exactly why enforcement was missing.
      class UnavailableError < StandardError; end

      attr_reader :agent_run, :backend, :snapshot, :adapter

      def initialize(agent_run:, backend:, snapshot:, adapter:)
        @agent_run = agent_run
        @backend = backend
        @snapshot = snapshot
        @adapter = adapter
      end

      # Materializes the gateway on the host backing +backend+ and
      # installs the per-run allowlist so the gateway can filter
      # outbound traffic. Adapters are required to fail closed: if the
      # gateway cannot be brought up or the allowlist cannot be
      # installed, the call MUST raise so the runner aborts provisioning
      # rather than starting a container with no enforcement.
      def ensure!
        adapter.ensure!(agent_run: agent_run, snapshot: snapshot, backend: backend)
        adapter.install_allowlist!(agent_run: agent_run, snapshot: snapshot, backend: backend)
      end

      # Returns the gateway URL as +host:port+ for the runner to allow
      # through the in-container firewall. +host+ is whatever the backend's
      # egress namespace uses (default +egress-gateway+).
      def gateway_url
        adapter.gateway_url(snapshot: snapshot, backend: backend)
      end

      # Returns the gateway's per-run allowlist (host patterns it will let
      # through) so the runner can also express it in iptables/NetworkPolicy
      # rules and the gateway's denials carry the same shape as the snapshot.
      def allowlist_for
        adapter.allowlist_for(snapshot: snapshot)
      end

      # Collects denial events from the gateway sidecar and persists
      # them as {EgressSecurityEvent} rows. Call after the run completes
      # so the audit trail includes every denied request the gateway
      # logged during execution.
      def collect_denials!
        denials = adapter.collect_denials(agent_run: agent_run, backend: backend)
        denials.each do |denial|
          record_denial!(
            host: denial[:host],
            port: denial[:port],
            matched_rule: denial[:matched_rule],
            scheme: denial[:scheme]
          )
        end
      end

      # Removes the per-run allowlist installed by {#ensure!} from the
      # gateway. Call as part of the runner's post-run cleanup, alongside
      # {#collect_denials!}, so a shared long-lived gateway sidecar does not
      # retain a stale allowlist file for every restricted run that has ever
      # executed on the host.
      def remove_allowlist!
        adapter.remove_allowlist!(agent_run: agent_run, backend: backend)
      end

      # Records a denied egress attempt against the gateway so operators
      # see +agent_run_id+, host, port, and matched/failed rule context.
      def record_denial!(host:, port:, matched_rule:, scheme: nil,
        egress_allowlist_entry: nil)
        EgressSecurityEvent.create!(
          account: agent_run.project.account,
          project: agent_run.project,
          agent_run: agent_run,
          egress_allowlist_entry: egress_allowlist_entry,
          event_kind: "denied_egress",
          severity: "warn",
          source_layer: "gateway",
          destination_host: host,
          destination_port: port,
          scheme: scheme,
          matched_rule: matched_rule,
          occurred_at: Time.current
        )
      end
    end
  end
end
