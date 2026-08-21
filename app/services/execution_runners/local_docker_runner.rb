# frozen_string_literal: true

module ExecutionRunners
# Thin adapter that wraps the existing +Containers::Provision+ Docker
# orchestrator behind the provider-neutral +ExecutionRunners::Base+
# interface (RDR-054). Translates {RunSpec}/{RunnerHandle}/{ExecutionResult}
# domain objects to and from +Containers::Provision+ calls.
#
# This runner owns the +NetworkingPolicy+ → Docker-network translation: it
# is the only place that calls +NetworkPolicy.ensure_network!+ and
# +NetworkPolicy.apply_firewall_rules+. +Containers::Provision+ accepts the
# +networking_policy+ for read-only Docker-config decisions (proxy URL,
# network name) but skips its own network/firewall side effects when a
# policy is provided.
#
# +RunnerHandle#metadata+ carries everything needed to reconnect to the
# container on a later call (agent_run id, worktree_path, environment),
# since +#start+/+#running?+/+#cancel+/+#cleanup+ only receive the handle.
#
# @spec CONTAINER-RUNTIME-010
# @spec CONTAINER-RUNTIME-011
# @spec CONTAINER-RUNTIME-012
# @spec CONTAINER-RUNTIME-013
# @spec CONTAINER-RUNTIME-014
# @spec CONTAINER-RUNTIME-017
# @spec CONTAINER-RUNTIME-028
# @spec EGRESS-POLICY-007
class LocalDockerRunner < Base
    RUNNER_TYPE = :local_docker

    # Prefix for per-run Docker named volumes. Volume-name construction lives
    # here (inside the runner) so no orchestration code or domain model builds
    # Docker volume names (RDR-054).
    WORKSPACE_VOLUME_PREFIX = "paid-workspace"

    # Default adapter registered for this runner. Specs may override per
    # test by stubbing {.gateway_adapter}; production callers always see
    # the Docker adapter because every LocalDockerRunner backend talks to
    # a Docker daemon.
    # @spec EGRESS-POLICY-007
    def self.gateway_adapter
      AgentRuns::EgressPolicy::GatewayAdapters::Docker.new
    end

    def provision(spec:)
      backend = backend_for(spec)
      policy = spec.networking_policy
      raise ProvisionError, "RunSpec requires a NetworkingPolicy" if policy.nil?
      raise ProvisionError, self.class.unsupported_policy_message(policy) unless self.class.supports_policy?(policy)
      raise ProvisionError, "RunSpec requires an IngressPolicy" if spec.ingress_policy.nil?
      spec.ingress_policy.validate_supported!

      gateway = build_gateway(spec: spec, backend: backend)
      enforce_gateway!(gateway: gateway)

      ensure_agent_network!(backend: backend, policy: policy)
      service = Containers::Provision.new(
        agent_run: spec.agent_run,
        project: spec.project,
        worktree_path: self.class.worktree_path_for(spec),
        backend: backend,
        networking_policy: policy,
        egress_gateway_url: gateway&.gateway_url,
        **provision_options(spec)
      )
      result = service.provision
      apply_firewall!(service: service, backend: backend, policy: policy, gateway: gateway)
      handle_for(spec: spec, result: result)
    rescue Containers::Provision::ProvisionError => e
      raise ProvisionError, e.message
    rescue ProvisionError
      # The container is already provisioned and running by the time the
      # runner raises its own error (the production firewall failure path in
      # #apply_firewall!); +Containers::Provision#provision+ only cleans up
      # failures raised inside itself. Clean up the live container before
      # re-raising so a firewall gap does not also leak an orphaned container
      # on the restricted network. Cleanup is best-effort — a partially-started
      # container may resist removal, and that must not mask the original
      # error.
      begin
        service.cleanup if service
      rescue StandardError
        # Surface the original provisioning error, not the cleanup error.
      end
      raise
    end

    # @spec CONTAINER-RUNTIME-019
    def start(handle:, command:, timeout: nil, startup_timeout: nil, idle_timeout: nil,
              abort_patterns: nil, preparation: nil, heartbeat_path: nil, &block)
      result = reconnect(handle: handle).execute(
        command, timeout: timeout, startup_timeout: startup_timeout, idle_timeout: idle_timeout,
        env: handle.metadata["environment"] || {}, preparation: preparation,
        heartbeat_path: heartbeat_path, abort_patterns: abort_patterns, &block
      )
      translate_result(result)
    rescue Containers::Provision::StartupTimeoutError => e
      raise StartupTimeoutError.new(e.message, diagnostics: e.diagnostics)
    rescue Containers::Provision::IdleTimeoutError => e
      raise IdleTimeoutError.new(e.message, diagnostics: e.diagnostics)
    rescue Containers::Provision::TimeoutError => e
      raise TimeoutError.new(e.message, diagnostics: e.diagnostics)
    rescue Containers::Provision::OutputAbortError => e
      raise OutputAbortError.new(e.message, matched_output: e.matched_output, source: e.source, detail: e.detail)
    rescue Containers::Provision::ExecutionError => e
      raise ExecutionError.new(e.message, exit_code: e.exit_code, stdout: e.stdout, stderr: e.stderr)
    rescue Containers::Provision::ProvisionError => e
      raise ProvisionError, e.message
    end

    def running?(handle:)
      reconnect(handle: handle).container_running?
    rescue Containers::Provision::ProvisionError
      false
    end

    # Reconnect to an existing Docker container from a persisted handle.
    # Translates the handle's identifier back to a Docker container ID and
    # delegates to +Containers::Provision.reconnect+. Used by Temporal activity
    # retries to recover after a worker restart/failover (RDR-054).
    def reconnect(handle:)
      agent_run = AgentRun.find(handle.metadata["agent_run_id"])
      Containers::Provision.reconnect(
        agent_run: agent_run, container_id: handle.identifier,
        worktree_path: handle.metadata["worktree_path"]
      )
    rescue ActiveRecord::RecordNotFound
      # A missing AgentRun means the environment can no longer be reached.
      # Translate to ProvisionError so every lifecycle method's existing
      # rescue maps it to the right "gone" outcome (not_found / false / nil).
      raise Containers::Provision::ProvisionError, "AgentRun not found"
    end

    # @spec CONTAINER-RUNTIME-015
    def status(handle:)
      state = reconnect(handle: handle).container_status
      return ExecutionStatus.not_found if state.empty?

      ExecutionStatus.new(
        state: classify_status(state),
        exit_code: state[:exit_code],
        oom_killed: state[:oom_killed],
        memory_limit: state[:memory_limit_bytes]
      )
    rescue Containers::Provision::ProvisionError
      ExecutionStatus.not_found
    end

    def cancel(handle:)
      service = reconnect(handle: handle)
      return unless service.container_running?

      # Containers::Provision#stop_container is private (only called from
      # #cleanup), so a best-effort stop that leaves the container in place
      # for #cleanup to remove goes through the backend directly, mirroring
      # what that private method does internally.
      service.backend.stop_container(service.container, timeout: 10)
      nil
    rescue Containers::Provision::ProvisionError, Docker::Error::NotFoundError
      nil
    end

    def cleanup(handle:, force: false)
      drain_gateway_denials!(handle: handle)
      reconnect(handle: handle).cleanup(force: force)
      nil
    rescue Containers::Provision::ProvisionError
      nil
    end

    # Removes the named Docker workspace volume for an agent run when it exists.
    # Used as the orphan-volume safety net: a worker killed mid-provision may
    # have created the volume without ever recording a container_id, so cleanup
    # routes by volume name (constructed here, inside the runner) instead of via
    # a recovered handle. Volume-name construction is owned by the runner so the
    # domain model never builds Docker volume names (#3342).
    #
    # @param agent_run [AgentRun] the run whose workspace volume may be orphaned
    # @param host [String, nil] owning backend host (resolved by the caller)
    # @return [void]
    def cleanup_workspace_reference(agent_run:, host: nil)
      volume_name = self.class.workspace_volume_name_for(agent_run.id)
      backend = Containers.backend_for(host)
      backend.delete_volume(backend.get_volume(volume_name, host: host))
    rescue Docker::Error::NotFoundError
      # Volume already removed, nothing to do
    rescue Docker::Error::DockerError => e
      Rails.logger.warn(
        message: "container_manager.orphaned_volume_cleanup_failed",
        agent_run_id: agent_run.id,
        volume_name: volume_name,
        error: e.message
      )
    end

    def self.compatible?(spec:, backend:)
      result = Containers::Provision.compatibility_for(
        agent_run: spec.agent_run, backend: backend, worktree_path: worktree_path_for(spec)
      )
      return CompatibilityResult.new(compatible: false, error_message: result.error_message) unless result.compatible

      policy = spec.networking_policy
      unless supports_policy?(policy)
        return CompatibilityResult.new(
          compatible: false,
          error_message: unsupported_policy_message(policy)
        )
      end

      # Restricted policies must be enforceable: a runtime without a
      # gateway adapter cannot honor the RDR-055 domain-aware allowlist,
      # so the spec is rejected before any Docker side effect rather than
      # starting a container with no enforcement. The adapter also has to
      # declare the backend eligible ({GatewayAdapters::Base#capable?}) —
      # Kubernetes and managed-machine adapters answer +false+ for
      # non-matching backends, so a future runner that returns an adapter
      # instance does not silently start a container with no enforcement.
      if policy.restricted? && !egress_capable?(spec: spec, backend: backend)
        return CompatibilityResult.new(
          compatible: false,
          error_message: "Runtime cannot enforce the egress policy snapshot on this backend; register a capable gateway adapter or reject the run"
        )
      end

      CompatibilityResult.new(compatible: true, error_message: nil)
    end

    # Returns true when the registered gateway adapter can enforce the
    # restricted policy on +backend+. Both legs must pass: the runner must
    # have an adapter registered, and that adapter must answer +true+ from
    # {GatewayAdapters::Base#capable?}. Adapters that depend on platform
    # primitives (CNI without NetworkPolicy, provider firewalls without
    # per-host filters) use +capable?+ to opt out per backend rather than
    # letting +#ensure!+ raise later in the provision path. The snapshot
    # is best-effort: it may not be persisted yet at scheduling time, so
    # adapters that need it implement +capable?+ defensively.
    # @spec EGRESS-POLICY-007
    def self.egress_capable?(spec:, backend:)
      adapter = gateway_adapter
      return false if adapter.nil?

      snapshot = AgentRuns::EgressPolicy::Snapshot.from_record(spec.agent_run)
      adapter.capable?(snapshot: snapshot, backend: backend)
    end

    # Single source of truth for the unsupported-policy error message, shared
    # by +.compatible?+ (rejects before scheduling) and +#provision+ (rejects
    # before any Docker side effect).
    def self.unsupported_policy_message(policy)
      "Runner does not support networking policy #{policy&.mode.inspect}"
    end

    # Docker supports every RDR-062 networking intent: the four restricted
    # intents use the existing +paid_agent+ network + iptables allowlist and
    # the two unrestricted intents use +paid_internal+ with no firewall. A
    # future remote runner returns +false+ for the intents its native egress
    # primitives cannot implement so the queue scheduler rejects the spec
    # before any provision attempt.
    # @spec CONTAINER-RUNTIME-028
    def self.supports_policy?(policy)
      policy.present? && ExecutionRunners::NETWORKING_POLICY_KNOWN_MODES.include?(policy.mode)
    end

    def self.ping
      Containers::HealthCheck.ping(Containers.backend).healthy?
    end

    # Only a legacy bind-mount workspace strategy needs a host worktree path;
    # :named_volume and :ephemeral both use Provision's default in-container
    # clone into a named Docker volume.
    def self.worktree_path_for(spec)
      return nil unless spec.workspace&.bind_mount?

      spec.workspace.reference
    end

    # Constructs the Docker named-volume name for an agent run. Centralized here
    # so volume-name construction never leaks into orchestration or the domain
    # model (#3342).
    def self.workspace_volume_name_for(agent_run_id)
      "#{WORKSPACE_VOLUME_PREFIX}-#{agent_run_id}"
    end

    # Ensures the agent Docker network exists, creating it if missing.
    # Class-level entry point for components that need network readiness
    # without going through the full runner lifecycle (e.g., embedding
    # runner, MCP sidecar provisioner). Delegates to the Docker-specific
    # +NetworkPolicy.ensure_network!+ so +NetworkPolicy+ stays the single
    # source of truth for Docker network lifecycle (RDR-054).
    def self.ensure_agent_network!(backend: Containers.backend)
      NetworkPolicy.ensure_network!(backend: backend)
    end

    # Applies iptables firewall rules inside a running container.
    # Class-level entry point for components that need container-level
    # firewall without a full runner lifecycle (e.g., embedding runner).
    # Delegates to the Docker-specific +NetworkPolicy.apply_firewall_rules+.
    def self.apply_firewall_rules(container, **kwargs)
      NetworkPolicy.apply_firewall_rules(container, **kwargs)
    end

    private

    # Maps the raw Docker state inspection to an ExecutionStatus state:
    # a running workload wins over OOM (a container can show OOMKilled=true
    # on a prior probe while still running), otherwise OOM precedes a plain
    # exit.
    def classify_status(state)
      return :running if state[:running]
      return :oom_killed if state[:oom_killed]

      :exited
    end

    def backend_for(spec)
      Containers.backend_for(spec.agent_run&.workspace_volume_host)
    end

    # Translates the runner-level +NetworkingPolicy+ into the Docker side
    # effect of ensuring the right network exists. +NetworkPolicy+ maps the
    # policy mode to the +paid_agent+ / +paid_internal+ Docker network names
    # — the runner never sees those literals.
    def ensure_agent_network!(backend:, policy:)
      network_name = NetworkPolicy.contract_for_policy(policy).network
      NetworkPolicy.ensure_network!(network: network_name, backend: backend)
    rescue NetworkPolicy::Error => e
      raise ProvisionError, "Network setup failed: #{e.message}"
    end

    # Applies the in-container firewall when the policy demands one. Firewall
    # destinations (service container IPs plus the preview-tunnel destination)
    # are resolved from the Provision service after containers start, so the
    # runner never inspects Docker network or preview-tunnel state directly.
    # +policy.allow_destinations+ uses the provider-neutral +{host:, port:}+
    # shape, so entries are normalized to +{ip:, port:}+ to match
    # +NetworkPolicy.build_firewall_script+, which reads +dest[:ip]+.
    #
    # The four restricted RDR-062 intents determine which default
    # destinations the firewall allows:
    #
    # - +:no_outbound+       — nothing; loopback + DNS only.
    # - +:proxy_only+        — Paid secrets proxy + DNS.
    # - +:git_plus_proxy+    — adds GitHub CIDR ranges.
    # - +:approved_services+ — adds service container IPs (current default).
    #
    # Service container IPs (+service.firewall_service_destinations+) are only
    # added for the +:approved_services+ intent; the narrower restricted
    # intents exclude them so their allowlist matches the RDR-062 mapping
    # table. Caller-supplied +allow_destinations+ are always honored.
    #
    # The snapshot's tenant-allowlisted destinations are NOT threaded into
    # the iptables rules: that would let the agent connect straight to
    # +api.partner.com:443+ without ever touching the egress gateway,
    # bypassing the gateway's domain-aware filtering and the structured
    # denial audit trail (EGRESS-POLICY-007). The gateway URL is opened so
    # HTTP(S) traffic can reach the gateway, and the gateway's own
    # allowlist (built from the snapshot's destinations) is what enforces
    # the per-run domain policy.
    def apply_firewall!(service:, backend:, policy:, gateway: nil)
      return unless policy.firewall?

      destinations = policy.allow_destinations.map { |dest| { ip: dest.fetch(:host), port: dest.fetch(:port) } }
      destinations += service.firewall_service_destinations if policy.approved_services?
      destinations += gateway_destinations(gateway) if gateway
      github_ips = github_ranges_for(policy)

      NetworkPolicy.apply_firewall_rules(
        service.container,
        github_ips: github_ips,
        proxy_host: proxy_host_for(policy),
        service_destinations: destinations,
        backend: backend
      )
    rescue NetworkPolicy::Error => e
      Rails.logger.warn(
        message: "container.firewall.failed",
        error: e.message,
        agent_run_id: service.agent_run&.id
      )
      # Firewall rules are defense-in-depth — they restrict outbound traffic
      # but the container is already on a restricted Docker network. Raising
      # in dev/test/CI would block local development on hosts without iptables
      # (e.g., macOS Docker Desktop, some CI runners). Production always
      # raises: a firewall gap on a live deployment is a security incident.
      raise ProvisionError, "Firewall setup failed: #{e.message}" if Rails.env.production?
    end

    # Builds the per-run egress gateway from the snapshot persisted on
    # +agent_run+. Only restricted policies need a gateway: {Resolve}
    # persists a snapshot for unrestricted policies too (e.g.
    # +subscription_auth+/+direct_outbound+), so gating on the snapshot's
    # presence alone would build a gateway — and later call
    # {enforce_gateway!} — for open runs that were never meant to go
    # through one. Open runs pass +nil+ to
    # {NetworkPolicy.apply_firewall_rules} and {apply_firewall!} skips the
    # gateway destinations entirely.
    def build_gateway(spec:, backend:)
      policy = spec.networking_policy
      return nil unless policy&.restricted?

      snapshot = AgentRuns::EgressPolicy::Snapshot.from_record(spec.agent_run)
      return nil unless snapshot

      adapter = self.class.gateway_adapter
      AgentRuns::EgressPolicy::Gateway.new(
        agent_run: spec.agent_run, backend: backend, snapshot: snapshot, adapter: adapter
      )
    end

    # Fail-closed enforcement: restricted policies must reach a gateway
    # that can translate their snapshot. Adapters raise
    # {Gateway::UnavailableError} when they cannot install the gateway;
    # production always re-raises as ProvisionError so the container is
    # not started without enforcement.
    def enforce_gateway!(gateway:)
      return unless gateway

      gateway.ensure!
    rescue AgentRuns::EgressPolicy::Gateway::UnavailableError => e
      Rails.logger.warn(
        message: "container.egress_gateway.failed",
        error: e.message,
        agent_run_id: gateway.agent_run.id
      )
      raise ProvisionError, "Egress gateway setup failed: #{e.message}" if Rails.env.production?
    end

    # Drains denial events from the per-host egress gateway into
    # {EgressSecurityEvent} rows for the run that just finished. This
    # is the live call site for {Gateway#collect_denials!} — without it
    # the gateway would only ever be exercised in unit tests, and a
    # restricted run would enforce via the sidecar but never persist
    # any denials to the audit trail.
    #
    # Only restricted runs (those that provisioned a gateway at
    # {#provision} time, gated by +networking_policy.restricted?+ and a
    # persisted snapshot) need a drain: an unrestricted run never
    # touched the gateway, so draining it returns no rows and would
    # only burn a Docker exec against the shared sidecar.
    #
    # Best-effort and idempotent: failures are logged but never raised
    # because {#cleanup} must remain safe to call on an already
    # torn-down handle, and the adapter's per-run denial log path
    # truncates after read so a retry cannot duplicate audit rows.
    # @spec EGRESS-POLICY-007
    def drain_gateway_denials!(handle:)
      agent_run_id = handle.metadata["agent_run_id"]
      return if agent_run_id.blank?

      agent_run = AgentRun.find_by(id: agent_run_id)
      return unless agent_run

      snapshot = AgentRuns::EgressPolicy::Snapshot.from_record(agent_run)
      return unless snapshot && restricted_snapshot_mode?(snapshot.mode)

      backend = Containers.backend_for(handle.host)
      adapter = self.class.gateway_adapter
      return unless adapter

      AgentRuns::EgressPolicy::Gateway.new(
        agent_run: agent_run, backend: backend, snapshot: snapshot, adapter: adapter
      ).collect_denials!
    rescue StandardError => e
      Rails.logger.warn(
        message: "container.gateway.denial_drain_failed",
        agent_run_id: handle.metadata["agent_run_id"],
        error: e.message
      )
      nil
    end

    # Whether the snapshot's persisted mode corresponds to one of the
    # restricted RDR-062 networking intents. Used by
    # {#drain_gateway_denials!} to skip unrestricted runs that never
    # installed a gateway, mirroring {#build_gateway}'s
    # +networking_policy.restricted?+ gate at provision time.
    def restricted_snapshot_mode?(mode)
      ExecutionRunners::NETWORKING_POLICY_RESTRICTED_MODES.include?(mode.to_sym)
    end

    # Translates the gateway's +host:port+ URL into the +{ip:, port:}+
    # shape +NetworkPolicy.apply_firewall_rules+ expects so the container
    # can reach the gateway without going through DNS. The gateway URL is
    # the platform's network alias (Docker) or service DNS (Kubernetes)
    # and is already validated at adapter construction time.
    def gateway_destinations(gateway)
      url = gateway.gateway_url
      host, port = url.split(":", 2)
      return [] if host.blank? || port.blank?

      [ { ip: host, port: Integer(port) } ]
    rescue ArgumentError
      []
    end

    # Returns the GitHub CIDR ranges the firewall should allow for the given
    # policy intent. +:no_outbound+ and +:proxy_only+ restrict egress so
    # tightly that direct GitHub access is denied — the agent must reach Git
    # through the Paid proxy or another tunnel.
    def github_ranges_for(policy)
      return [] if %i[no_outbound proxy_only].include?(policy.mode)

      NetworkPolicy::DEFAULT_GITHUB_IPS
    end

    # Returns the proxy host the firewall should allow. +false+ tells
    # +NetworkPolicy.apply_firewall_rules+ to omit the proxy allow rule
    # entirely, which is what the RDR-062 :no_outbound intent demands.
    def proxy_host_for(policy)
      return false if policy.no_outbound?

      nil
    end

    def provision_options(spec)
      options = {}
      options[:image] = spec.image if spec.image.present?
      resources = spec.resources
      return options unless resources

      options[:memory_bytes] = resources.memory_bytes if resources.memory_bytes
      options[:cpu_quota] = resources.cpu_quota if resources.cpu_quota
      options[:pids_limit] = resources.pids_limit if resources.pids_limit
      options
    end

    def handle_for(spec:, result:)
      RunnerHandle.new(
        runner_type: RUNNER_TYPE,
        identifier: result[:container_id],
        host: result[:container_host],
        workspace_ref: workspace_reference_for(spec),
        metadata: {
          "agent_run_id" => spec.agent_run&.id,
          "worktree_path" => self.class.worktree_path_for(spec),
          "environment" => spec.environment || {}
        }
      )
    end

    # Translates the {WorkspaceStrategy} into the opaque workspace reference
    # carried on the handle: the bind-mount host path for legacy worktrees, or
    # the Docker named-volume name (constructed here) for named-volume runs.
    def workspace_reference_for(spec)
      return spec.workspace.reference if spec.workspace&.bind_mount?

      self.class.workspace_volume_name_for(spec.agent_run&.id)
    end

    def translate_result(result)
      if result.success?
        ExecutionResult.success(stdout: result[:stdout], stderr: result[:stderr], exit_code: result[:exit_code])
      else
        ExecutionResult.failure(
          exit_code: result[:exit_code], stdout: result[:stdout], stderr: result[:stderr],
          oom_killed: result[:oom_killed] || false, memory_limit_bytes: result[:memory_limit_bytes],
          environment_running: result[:container_running]
        )
      end
    end
end
end
