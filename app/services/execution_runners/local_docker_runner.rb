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
  class LocalDockerRunner < Base
    RUNNER_TYPE = :local_docker

    def provision(spec:)
      backend = backend_for(spec)
      policy = spec.networking_policy
      raise ProvisionError, "RunSpec requires a NetworkingPolicy" if policy.nil?

      ensure_agent_network!(backend: backend, policy: policy)
      service = Containers::Provision.new(
        agent_run: spec.agent_run,
        project: spec.project,
        worktree_path: self.class.worktree_path_for(spec),
        backend: backend,
        networking_policy: policy,
        **provision_options(spec)
      )
      result = service.provision
      apply_firewall!(service: service, backend: backend, policy: policy)
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

    def start(handle:, command:, timeout: nil, startup_timeout: nil, idle_timeout: nil,
              abort_patterns: nil, preparation: nil, heartbeat_path: nil)
      result = reconnect(handle).execute(
        command, timeout: timeout, startup_timeout: startup_timeout, idle_timeout: idle_timeout,
        env: handle.metadata["environment"] || {}, preparation: preparation,
        heartbeat_path: heartbeat_path, abort_patterns: abort_patterns
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
      reconnect(handle).container_running?
    rescue Containers::Provision::ProvisionError
      false
    end

    def cancel(handle:)
      service = reconnect(handle)
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
      reconnect(handle).cleanup(force: force)
      nil
    rescue Containers::Provision::ProvisionError
      nil
    end

    def self.compatible?(spec:, backend:)
      result = Containers::Provision.compatibility_for(
        agent_run: spec.agent_run, backend: backend, worktree_path: worktree_path_for(spec)
      )
      CompatibilityResult.new(compatible: result.compatible, error_message: result.error_message)
    end

    def self.ping
      Containers::HealthCheck.ping(Containers.backend).healthy?
    end

    # Only a legacy bind-mount workspace strategy needs a host worktree path;
    # :named_volume and :ephemeral both use Provision's default in-container
    # clone into a named Docker volume.
    def self.worktree_path_for(spec)
      return nil unless spec.workspace_strategy == :bind_mount

      spec.agent_run&.worktree_path
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

    # Applies the in-container firewall when the policy demands one. Service
    # container IPs are resolved from the Provision service after containers
    # start. +policy.allow_destinations+ uses the provider-neutral
    # +{host:, port:}+ shape, so entries are normalized to +{ip:, port:}+ to
    # match +NetworkPolicy.build_firewall_script+, which reads +dest[:ip]+.
    def apply_firewall!(service:, backend:, policy:)
      return unless policy.firewall?

      destinations = policy.allow_destinations.map { |dest| { ip: dest.fetch(:host), port: dest.fetch(:port) } } + service.resolve_service_destinations

      NetworkPolicy.apply_firewall_rules(
        service.container,
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
        workspace_ref: self.class.worktree_path_for(spec) || "paid-workspace-#{spec.agent_run&.id}",
        metadata: {
          "agent_run_id" => spec.agent_run&.id,
          "worktree_path" => self.class.worktree_path_for(spec),
          "environment" => spec.environment || {}
        }
      )
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

    def reconnect(handle)
      agent_run = AgentRun.find(handle.metadata["agent_run_id"])
      Containers::Provision.reconnect(
        agent_run: agent_run, container_id: handle.identifier,
        worktree_path: handle.metadata["worktree_path"]
      )
    end
  end
end
