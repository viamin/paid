# frozen_string_literal: true

require "json"

# ExecutionRunners defines the domain-oriented runner contract that will
# replace direct Docker API access in orchestration code (RDR-054).
#
# The contract is driven by what +Containers::Provision+ actually does today,
# not speculative generalization. It models the complete execution environment
# — primary workload, sidecars, services, network, and workspace — as a single
# lifecycle owned by a runner implementation.
#
# Intent flows: RunSpec (what to run) → runner.provision → RunnerHandle (opaque
# reference) → runner.start → ExecutionResult (outcome) → runner.cleanup.
#
# This module defines the interface value objects and the error hierarchy.
# Concrete runners subclass {ExecutionRunners::Base}.
#
# @see ExecutionRunners::Base
module ExecutionRunners
  # Resolves the concrete runner for a backend/runner descriptor. All current
  # backends (local Docker, remote Docker, Swarm) are Docker transports, so
  # they all resolve to {LocalDockerRunner} today; a future non-Docker runner
  # (e.g. a remote-machine runner) adds a branch here rather than changing
  # callers (RDR-054).
  #
  # @param backend [Object] backend/runner descriptor to resolve a runner for
  # @return [Base] a runner instance
  # @spec CONTAINER-RUNTIME-010
  def self.resolve(backend:)
    LocalDockerRunner.new
  end

  # Convenience resolver that derives the backend from an agent run.
  # All current backends (local Docker, remote Docker, Swarm) are Docker
  # transports, so every agent run resolves to {LocalDockerRunner} (RDR-054).
  # @param agent_run [AgentRun] the run to resolve a runner for
  # @return [Base]
  def self.resolve_for(agent_run)
    resolve(backend: Containers.backend_for(agent_run.workspace_volume_host))
  rescue Containers::Backends::Resolver::UnknownBackendError
    resolve(backend: nil)
  end

  # Compute resource limits for a workload. Mirrors the fields
  # +Containers::Provision::DEFAULTS+ actually consumes (memory_bytes,
  # cpu_quota, pids_limit). Runners translate these to their native
  # resource controls (cgroups, Fly machine size, etc.).
  # @spec CONTAINER-RUNTIME-009
  ComputeRequirements = Data.define(:cpu_quota, :memory_bytes, :pids_limit)

  # A writable directory inside the workload. A Docker runner translates this
  # to a tmpfs mount; a remote runner translates it to ephemeral disk or
  # platform-native writable storage. Declared on {WorkspaceStrategy} so the
  # writable layout travels with the workspace contract instead of being
  # hardcoded by orchestration code.
  #
  # The data shape and +docker_tmpfs_options+ helper exist so the runner can
  # translate the strategy's writable dirs into Docker tmpfs mounts when
  # CONTAINER-RUNTIME-012 lands; today +Containers::Provision#host_config+
  # still hardcodes its own +Tmpfs+ block.
  # @spec CONTAINER-RUNTIME-011
  # @spec CONTAINER-RUNTIME-012
  WritableDir = Data.define(:path, :size_bytes, :mode, :exec) do
    DEFAULT_MODE = 0o755

    def self.build(path, size_bytes:, mode: DEFAULT_MODE, exec: false)
      new(path: path, size_bytes: size_bytes, mode: mode, exec: exec)
    end

    # Docker tmpfs mount options string (e.g. +"exec,size=1073741824,mode=1777"+).
    # Used by the runner when it begins translating the strategy's writable
    # dirs into Provision calls (CONTAINER-RUNTIME-012).
    def docker_tmpfs_options
      parts = []
      parts << "exec" if exec
      parts << "size=#{size_bytes}"
      parts << "mode=#{format("%04o", mode)}"
      parts.join(",")
    end
  end

  # Heartbeat monitoring configuration carried by the workspace strategy. The
  # runner owns how the heartbeat path is made observable — a host bind mount
  # when the backend exposes host paths, an in-container tmpfs otherwise — so
  # callers never reach into Docker volume/tmpfs mechanics.
  #
  # Declared on the strategy as the provider-neutral shape today so callers
  # can begin expressing heartbeat needs on the strategy; the actual
  # runner-owned translation lands with CONTAINER-RUNTIME-013, after which
  # +LocalDockerRunner#start+ reads +workspace.heartbeat+ instead of taking
  # +heartbeat_path:+ directly.
  # @spec CONTAINER-RUNTIME-011
  # @spec CONTAINER-RUNTIME-013
  HeartbeatConfig = Data.define(:mount_point)

  # Provider-neutral workspace/storage strategy, isolating workspace assumptions
  # from Docker volumes and bind mounts (RDR-054). A runner implementation
  # translates the mode into its native storage primitive:
  #
  #   :named_volume    — runner-managed named volume (Docker: +paid-workspace-<id>+)
  #   :bind_mount      — an existing host path mounted into the workload (legacy worktree)
  #   :ephemeral       — ephemeral container-local storage, no persistence
  #   :object_storage  — remote object storage synced into the workload (future)
  #
  # +reference+ is nil until a runner provisions storage; afterwards it holds
  # the opaque storage reference (volume name, host path, or storage URI) that
  # {RunnerHandle#workspace_ref} carries for recovery and cleanup. Volume-name
  # construction lives inside the runner, never in orchestration or the domain
  # model.
  # @spec CONTAINER-RUNTIME-011
  WorkspaceStrategy = Data.define(:mode, :mount_point, :reference, :writable_dirs, :heartbeat) do
    DEFAULT_MOUNT_POINT = "/workspace"
    HEARTBEAT_MOUNT_POINT = "/paid-heartbeat"

    # Default writable directories every workload needs (scratch + tool cache).
    # Runner-specific credential tmpfs mounts (e.g. ~/.claude, ~/.codex) are a
    # Docker-implementation detail owned by the runner, not part of the
    # provider-neutral workspace contract.
    def self.default_writable_dirs
      [
        WritableDir.build("/tmp", size_bytes: 1024 * 1024 * 1024, mode: 0o1777, exec: true),
        WritableDir.build("/home/agent/.cache", size_bytes: 512 * 1024 * 1024, mode: 0o755, exec: true)
      ]
    end

    def self.named_volume(mount_point: DEFAULT_MOUNT_POINT,
                          writable_dirs: default_writable_dirs)
      new(mode: :named_volume, mount_point: mount_point, reference: nil,
          writable_dirs: writable_dirs, heartbeat: HeartbeatConfig.new(mount_point: HEARTBEAT_MOUNT_POINT))
    end

    def self.bind_mount(reference:, mount_point: DEFAULT_MOUNT_POINT,
                        writable_dirs: default_writable_dirs)
      new(mode: :bind_mount, mount_point: mount_point, reference: reference,
          writable_dirs: writable_dirs, heartbeat: HeartbeatConfig.new(mount_point: HEARTBEAT_MOUNT_POINT))
    end

    def self.ephemeral(mount_point: DEFAULT_MOUNT_POINT,
                       writable_dirs: default_writable_dirs)
      new(mode: :ephemeral, mount_point: mount_point, reference: nil,
          writable_dirs: writable_dirs, heartbeat: HeartbeatConfig.new(mount_point: HEARTBEAT_MOUNT_POINT))
    end

    def named_volume?
      mode == :named_volume
    end

    def bind_mount?
      mode == :bind_mount
    end
  end

  # Immutable description of what to execute. Built by orchestration from the
  # +AgentRun+/+Project+ context and handed to {ExecutionRunners::Base#provision}.
  # @spec CONTAINER-RUNTIME-009
  # @spec CONTAINER-RUNTIME-011
  RunSpec = Data.define(
    :agent_run,          # AgentRun context
    :project,            # Project context
    :image,              # Workload image
    :command,            # Agent command to execute
    :resources,          # ComputeRequirements (cpu, memory, pids)
    :environment,        # Hash of env vars
    :networking_policy,  # NetworkingPolicy (restricted vs. direct)
    :workspace,          # WorkspaceStrategy (named_volume | bind_mount | ephemeral)
    :services,           # Array<ServiceDeclaration>
    :secrets_config,     # Auth/credential configuration
    :preview_tunnel      # Optional preview tunnel config
  ) do
    # Builds a RunSpec from an AgentRun context for the shim migration path
    # (RDR-054). Derives the workspace strategy, resource limits, and networking
    # policy from the agent run and its project.
    # @param agent_run [AgentRun]
    # @param options [Hash] container options (memory_bytes, cpu_quota, etc.)
    # @return [RunSpec]
    def self.from_agent_run(agent_run, **options)
      resources = if options[:memory_bytes] || options[:cpu_quota] || options[:pids_limit]
                    ComputeRequirements.new(
                      cpu_quota: options[:cpu_quota],
                      memory_bytes: options[:memory_bytes],
                      pids_limit: options[:pids_limit]
                    )
      end

      new(
        agent_run: agent_run,
        project: agent_run.project,
        image: options[:image],
        command: nil, # Set at start time
        resources: resources,
        environment: agent_run.service_environment || {},
        networking_policy: NetworkingPolicy.new(mode: :proxy, firewall: true),
        workspace: workspace_strategy_for(agent_run),
        services: [],
        secrets_config: nil,
        preview_tunnel: nil
      )
    end

    # Derives the workspace strategy from the agent run: a legacy bind mount
    # when an explicit worktree path is present, otherwise the default named
    # volume (in-container clone). Volume-name construction stays inside the
    # runner; the strategy only records the mode and host reference.
    def self.workspace_strategy_for(agent_run)
      worktree_path = agent_run.worktree_path.presence
      return WorkspaceStrategy.bind_mount(reference: worktree_path) if worktree_path

      WorkspaceStrategy.named_volume
    end
    private_class_method :workspace_strategy_for
  end

  # Opaque reference to a launched environment, returned by +#provision+ and
  # accepted by +#start+, +#running?+, +#cancel+, and +#cleanup+.
  #
  # Must be JSON-serializable so it can be stored in a DB column or Temporal
  # activity result, enabling a workflow to recover and continue observing or
  # cleaning up a remotely running execution after worker restart or failover.
  # All fields are JSON-native primitives; +#to_json+ / +.from_json+ round-trip
  # the +runner_type+ symbol losslessly.
  # @spec CONTAINER-RUNTIME-008
  RunnerHandle = Data.define(:runner_type, :identifier, :host, :workspace_ref, :metadata) do
    def as_json(*)
      {
        "runner_type" => runner_type.to_s,
        "identifier" => identifier,
        "host" => host,
        "workspace_ref" => workspace_ref,
        "metadata" => metadata
      }
    end

    def to_json(*args)
      as_json.to_json(*args)
    end

    # Reconstructs a handle from a JSON string or a string-keyed Hash.
    def self.from_json(payload)
      data = payload.is_a?(String) ? JSON.parse(payload) : payload.transform_keys(&:to_s)
      new(
        runner_type: data["runner_type"]&.to_sym,
        identifier: data["identifier"],
        host: data["host"],
        workspace_ref: data["workspace_ref"],
        metadata: data["metadata"] || {}
      )
    end
  end

  # Provider-neutral networking policy, replacing Docker network names.
  # Adapted from +NetworkPolicy::NetworkContract+ but drops the Docker-specific
  # +network+ name and derives restriction from +mode+. A runner implementation
  # translates this to Docker networks, in-container firewall rules, Fly
  # firewall rules, etc.
  #
  # +mode+ values:
  #   :proxy              — restricted; traffic flows through Paid's secrets proxy
  #   :subscription_auth  — unrestricted; provider CLI reaches upstream APIs directly
  #   :direct_outbound    — unrestricted; provider bypasses the proxy entirely
  # @spec CONTAINER-RUNTIME-009
  NetworkingPolicy = Data.define(:mode, :firewall) do
    RESTRICTED_MODE = :proxy

    def restricted?
      mode == RESTRICTED_MODE
    end

    def firewall?
      firewall
    end
  end

  # Provider-neutral service declaration, replacing Docker-specific service
  # provisioning. A runner translates this to the native sidecar/process model.
  #
  # +type+ values: :database | :cache | :browser | :mcp_sidecar | :custom
  # @spec CONTAINER-RUNTIME-009
  ServiceDeclaration = Data.define(:name, :image, :port, :env, :type)

  # Result of {ExecutionRunners::Base.compatible?}. Mirrors the shape of
  # +Containers::Provision::CompatibilityResult+ but lives in the
  # provider-neutral namespace so the abstract interface never references a
  # Docker-specific class.
  # @spec CONTAINER-RUNTIME-007
  CompatibilityResult = Data.define(:compatible, :error_message)

  # Snapshot of a workload's current state, returned by
  # {ExecutionRunners::Base#status}. Abstracts Docker container-state inspection
  # (+State.Running+, +State.OOMKilled+, +State.ExitCode+) behind a
  # provider-neutral shape so callers never reach into the Docker API response
  # directly (RDR-054).
  #
  # +state+ values:
  #   :running     — workload process is still active
  #   :exited      — workload has terminated (check +exit_code+)
  #   :oom_killed  — the platform's OOM killer terminated the workload
  #   :not_found   — the workload/environment no longer exists
  #
  # @spec CONTAINER-RUNTIME-015
  ExecutionStatus = Data.define(:state, :exit_code, :oom_killed, :memory_limit) do
    def running?
      state == :running
    end

    def exited?
      state == :exited
    end

    def oom_killed?
      state == :oom_killed
    end

    def not_found?
      state == :not_found
    end

    def self.running(memory_limit: nil)
      new(state: :running, exit_code: nil, oom_killed: false, memory_limit: memory_limit)
    end

    def self.exited(exit_code:, memory_limit: nil)
      new(state: :exited, exit_code: exit_code,
          oom_killed: false, memory_limit: memory_limit)
    end

    def self.oom_killed(exit_code:, memory_limit: nil)
      new(state: :oom_killed, exit_code: exit_code, oom_killed: true, memory_limit: memory_limit)
    end

    def self.not_found
      new(state: :not_found, exit_code: nil, oom_killed: false, memory_limit: nil)
    end
  end

  # Outcome of running a workload. Consolidates the existing
  # +Containers::Provision::Result+ patterns so callers no longer reach into
  # the Docker result object. Watchdog terminations (startup/idle/wall-clock
  # timeout, abort pattern / streaming-event match) are surfaced through the
  # typed error hierarchy (StartupTimeoutError, IdleTimeoutError, TimeoutError,
  # OutputAbortError) raised by +#start+ rather than as fields here, so this
  # value object only describes workloads that ran to an exit (RDR-054).
  # @spec CONTAINER-RUNTIME-009
  # @spec CONTAINER-RUNTIME-015
  ExecutionResult = Data.define(
    :success,             # Boolean
    :stdout,              # String
    :stderr,              # String
    :exit_code,           # Integer
    :oom_killed,          # Boolean
    :memory_limit_bytes,  # Integer, nil
    :environment_running  # Boolean, nil — whether the launched environment is
    # still running after the workload exited (used for OOM diagnostics)
  ) do
    def success?
      success
    end

    def failure?
      !success
    end

    def self.success(stdout: "", stderr: "", exit_code: 0)
      new(success: true, stdout: stdout, stderr: stderr, exit_code: exit_code,
          oom_killed: false, memory_limit_bytes: nil, environment_running: nil)
    end

    def self.failure(exit_code:, stdout: "", stderr: "",
                     oom_killed: false, memory_limit_bytes: nil, environment_running: nil)
      new(success: false, stdout: stdout, stderr: stderr, exit_code: exit_code,
          oom_killed: oom_killed, memory_limit_bytes: memory_limit_bytes,
          environment_running: environment_running)
    end
  end

  # Base error for all execution-runner errors.
  class Error < StandardError; end

  # Raised when provisioning the execution environment fails.
  class ProvisionError < Error
    def initialize(msg = "Failed to provision execution environment")
      super
    end
  end

  # Raised when a workload command fails to execute.
  class ExecutionError < Error
    attr_reader :exit_code, :stdout, :stderr

    def initialize(msg, exit_code: nil, stdout: nil, stderr: nil)
      @exit_code = exit_code
      @stdout = stdout
      @stderr = stderr
      super(msg)
    end
  end

  # Raised when an operation exceeds its time budget.
  class TimeoutError < Error
    attr_reader :diagnostics

    def initialize(msg = "Operation timed out", diagnostics: {})
      @diagnostics = diagnostics
      super(msg)
    end
  end

  # Raised when no output is received within the startup timeout.
  class StartupTimeoutError < TimeoutError
    def initialize(msg = "No output received within startup timeout", diagnostics: {})
      super(msg, diagnostics: diagnostics)
    end
  end

  # Raised when output stops flowing for longer than the idle timeout.
  class IdleTimeoutError < TimeoutError
    def initialize(msg = "No output received within idle timeout", diagnostics: {})
      super(msg, diagnostics: diagnostics)
    end
  end

  # Raised when streaming output matches an abort pattern (or a structured
  # streaming failure event) indicating a fatal runner error where the CLI is
  # known to hang instead of exiting.
  #
  # +source+ distinguishes abort origins:
  #   :pattern          — stderr/stdout matched a configured quota/rate-limit pattern
  #   :streaming_event  — a CLI streaming JSONL error/turn.failed event
  class OutputAbortError < Error
    attr_reader :matched_output, :source, :detail

    def initialize(msg = "Process aborted due to fatal output pattern",
                   matched_output: nil, source: :pattern, detail: nil)
      @matched_output = matched_output
      @source = source.to_sym
      @detail = detail
      super(msg)
    end
  end
end
