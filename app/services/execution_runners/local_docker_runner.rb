# frozen_string_literal: true

module ExecutionRunners
  # Thin adapter that wraps the existing +Containers::Provision+ Docker
  # orchestrator behind the provider-neutral +ExecutionRunners::Base+
  # interface (RDR-054). Translates {RunSpec}/{RunnerHandle}/{ExecutionResult}
  # domain objects to and from +Containers::Provision+ calls without
  # modifying +Containers::Provision+ itself.
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
  class LocalDockerRunner < Base
    RUNNER_TYPE = :local_docker

    # Prefix for per-run Docker named volumes. Volume-name construction lives
    # here (inside the runner) so no orchestration code or domain model builds
    # Docker volume names (RDR-054).
    WORKSPACE_VOLUME_PREFIX = "paid-workspace"

    def provision(spec:)
      service = Containers::Provision.new(
        agent_run: spec.agent_run,
        project: spec.project,
        worktree_path: self.class.worktree_path_for(spec),
        backend: backend_for(spec),
        **provision_options(spec)
      )
      handle_for(spec: spec, result: service.provision)
    rescue Containers::Provision::ProvisionError => e
      raise ProvisionError, e.message
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

    # @spec CONTAINER-RUNTIME-015
    def status(handle:)
      state = reconnect(handle).container_status
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
      CompatibilityResult.new(compatible: result.compatible, error_message: result.error_message)
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

    def reconnect(handle)
      agent_run = AgentRun.find(handle.metadata["agent_run_id"])
      Containers::Provision.reconnect(
        agent_run: agent_run, container_id: handle.identifier,
        worktree_path: handle.metadata["worktree_path"]
      )
    end
  end
end
