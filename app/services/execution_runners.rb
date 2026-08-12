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

  # Immutable description of what to execute. Built by orchestration from the
  # +AgentRun+/+Project+ context and handed to {ExecutionRunners::Base#provision}.
  # @spec CONTAINER-RUNTIME-009
  RunSpec = Data.define(
    :agent_run,          # AgentRun context
    :project,            # Project context
    :image,              # Workload image
    :command,            # Agent command to execute
    :resources,          # ComputeRequirements (cpu, memory, pids)
    :environment,        # Hash of env vars
    :networking_policy,  # NetworkingPolicy (restricted vs. direct)
    :workspace_strategy, # :named_volume | :bind_mount | :ephemeral
    :services,           # Array<ServiceDeclaration>
    :secrets_config      # Auth/credential configuration
  ) do
    # Builds a RunSpec from an AgentRun context for the shim migration path
    # (RDR-054). Derives workspace strategy and resource limits from the
    # agent run; the networking policy is the caller's responsibility so the
    # +NetworkingPolicy+ flows in as a domain object rather than being
    # reconstructed from Docker signals inside the runner.
    # @param agent_run [AgentRun]
    # @param networking_policy [NetworkingPolicy, nil] required networking policy
    # @param options [Hash] container options (memory_bytes, cpu_quota, etc.)
    # @return [RunSpec]
    def self.from_agent_run(agent_run, networking_policy: nil, **options)
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
        networking_policy: networking_policy,
        workspace_strategy: agent_run.worktree_path.present? ? :bind_mount : :named_volume,
        services: [],
        secrets_config: nil
      )
    end
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
  #   :proxy_restricted   — restricted; traffic flows through Paid's secrets proxy
  #                          and an in-container iptables firewall limits egress
  #                          to the proxy, GitHub IPs, DNS, and service containers.
  #   :subscription_auth  — unrestricted; provider CLI reaches upstream APIs directly.
  #   :direct_outbound    — unrestricted; provider bypasses the proxy entirely.
  #
  # +firewall+ (boolean) — whether the runner must apply in-container firewall
  #                          rules. Always true for +:proxy_restricted+, false
  #                          for the unrestricted modes.
  #
  # +allow_destinations+ — array of destination hashes ({host:, port:}) the
  #                          runner should grant in the firewall, in addition to
  #                          the secrets proxy and GitHub ranges. The runner
  #                          merges these with service container IPs (resolved
  #                          from Provision after containers start) and
  #                          preview-tunnel destinations, so the underlying
  #                          policy implementation never has to inspect Docker
  #                          network state.
  # @spec CONTAINER-RUNTIME-009
  # @spec CONTAINER-RUNTIME-011
  NetworkingPolicy = Data.define(:mode, :firewall, :allow_destinations) do
    RESTRICTED_MODE = :proxy_restricted

    def self.proxy_restricted(allow_destinations: [])
      new(mode: RESTRICTED_MODE, firewall: true, allow_destinations: allow_destinations)
    end

    def self.subscription_auth
      new(mode: :subscription_auth, firewall: false, allow_destinations: [])
    end

    def self.direct_outbound
      new(mode: :direct_outbound, firewall: false, allow_destinations: [])
    end

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

  # Outcome of running a workload. Consolidates the existing
  # +Containers::Provision::Result+ patterns so callers no longer reach into
  # the Docker result object.
  # @spec CONTAINER-RUNTIME-009
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
