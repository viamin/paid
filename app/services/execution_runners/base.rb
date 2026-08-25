# frozen_string_literal: true

module ExecutionRunners
  # Abstract interface for execution runners. A runner owns the complete
  # execution environment — primary workload, sidecars, services, network, and
  # workspace — as a single lifecycle (RDR-054).
  #
  # The interface is provider-neutral: method names and parameters never
  # reference Docker concepts (no container_id, network name, bind mount, or
  # exec). A concrete runner (e.g. a local Docker runner, a remote-machine
  # runner) translates the domain objects into its native API.
  #
  # Lifecycle:
  #   spec   = ExecutionRunners::RunSpec.new(...)
  #   handle = runner.provision(spec: spec)
  #   result = runner.start(handle: handle, command: ..., ...) { |stream, chunk| ... }
  #   runner.running?(handle: handle)
  #   runner.status(handle: handle) # => ExecutionStatus
  #   runner.cancel(handle: handle)
  #   runner.cleanup(handle: handle, force: true)
  #
  # Timeout and watchdog logic (startup timeout, idle timeout, wall-clock
  # timeout, heartbeat monitoring) is owned by the runner, not by callers.
  #
  # @abstract Subclass and override every method.
  # @spec CONTAINER-RUNTIME-007
  class Base
    # The kind of execution resource this runner provisions (e.g. "container"),
    # or nil when the runner cannot identify a resource kind. A runner that
    # returns nil skips the provisioning-intent ledger (CONTAINER-RUNTIME-025)
    # because it cannot attribute a created resource back to its Paid origin.
    # @return [String, nil]
    # @spec CONTAINER-RUNTIME-025
    def resource_kind
      nil
    end

    # Whether this runner/provider can apply ownership tags to a provisioned
    # resource. Defaults to false (conservative) so a remote runner that cannot
    # tag degrades explicitly instead of silently losing attribution
    # (CONTAINER-RUNTIME-026).
    # @return [Boolean]
    def supports_tagging?
      false
    end

    # Whether this runner/provider can list provisioned resources (for
    # reconciliation). Defaults to false (conservative).
    # @return [Boolean]
    def supports_listing?
      false
    end

    # Provision the execution environment (workspace, network, services, secrets).
    #
    # @param spec [RunSpec] immutable description of what to execute
    # @return [RunnerHandle] opaque reference to the launched environment,
    #   persisted for recovery across worker restart/failover
    # @raise [ProvisionError] when provisioning fails
    def provision(spec:)
      raise NotImplementedError, "#{self.class} must implement ##{__method__}"
    end

    # Start the agent workload (run the command inside the provisioned
    # environment). Streams stdout/stderr chunks to the given block to avoid
    # buffering entire outputs in memory. Returns the outcome of the workload.
    #
    # The runner owns the watchdog: startup timeout, idle timeout, wall-clock
    # timeout, abort-pattern detection, and heartbeat monitoring are enforced
    # here, raising the corresponding error type on breach.
    #
    # @param handle [RunnerHandle] reference returned by +#provision+
    # @param command [String, Array<String>] agent command to execute
    # @param timeout [Integer, nil] wall-clock timeout in seconds
    # @param startup_timeout [Integer, nil] max seconds to wait for first output
    # @param idle_timeout [Integer, nil] max seconds between output chunks
    # @param abort_patterns [Array<Regexp, String>, nil] fatal output patterns
    # @param preparation [Object, nil] execution-preparation descriptor the
    #   runner applies and restores around the workload
    # @param heartbeat_path [String, nil] host/container-visible heartbeat path
    # @yieldparam stream_type [Symbol] :stdout or :stderr
    # @yieldparam chunk [String] output chunk
    # @return [ExecutionResult]
    # @raise [StartupTimeoutError] no output within startup_timeout
    # @raise [IdleTimeoutError] output stops for longer than idle_timeout
    # @raise [TimeoutError] wall-clock timeout exceeded
    # @raise [OutputAbortError] fatal output pattern matched
    # @raise [ExecutionError] workload failed to execute
    # @spec CONTAINER-RUNTIME-019
    def start(handle:, command:, timeout:, startup_timeout:, idle_timeout:,
              abort_patterns:, preparation:, heartbeat_path:, &block)
      raise NotImplementedError, "#{self.class} must implement ##{__method__}"
    end

    # Query whether the workload is still running.
    #
    # @param handle [RunnerHandle]
    # @return [Boolean]
    def running?(handle:)
      raise NotImplementedError, "#{self.class} must implement ##{__method__}"
    end

    # Reconnect to an existing execution environment from a persisted handle.
    # Used by Temporal activities to recover after a worker restart or
    # failover: the activity loads the {RunnerHandle} from the DB and calls
    # +#reconnect+ before checking +#running?+ to decide whether to reuse the
    # environment or clean it up.
    #
    # @param handle [RunnerHandle] the persisted handle to reconnect from
    # @return [Object] a reconnected runner/service instance that can answer
    #   +#running?+, +#execute+, and +#cleanup+
    # @raise [ProvisionError] when the environment cannot be found
    def reconnect(handle:)
      raise NotImplementedError, "#{self.class} must implement ##{__method__}"
    end

    # Query the workload's lifecycle state. Unlike +#running?+ (a boolean
    # convenience), this returns a rich {ExecutionStatus} carrying state,
    # exit code, OOM flag, and memory limit so callers can classify the
    # outcome without reaching into platform-specific state inspection.
    #
    # @param handle [RunnerHandle]
    # @return [ExecutionStatus]
    # @spec CONTAINER-RUNTIME-015
    def status(handle:)
      raise NotImplementedError, "#{self.class} must implement ##{__method__}"
    end

    # Cancel an in-flight workload. Best-effort stop; the caller should still
    # +#cleanup+ to release all resources.
    #
    # @param handle [RunnerHandle]
    # @return [void]
    def cancel(handle:)
      raise NotImplementedError, "#{self.class} must implement ##{__method__}"
    end

    # Clean up all resources for the environment (workload, sidecars, services,
    # network, volume, temp files). Idempotent: a second cleanup for an already
    # torn-down handle must be a no-op.
    #
    # @param handle [RunnerHandle]
    # @param force [Boolean] force-kill rather than graceful stop
    # @return [void]
    def cleanup(handle:, force: false)
      raise NotImplementedError, "#{self.class} must implement ##{__method__}"
    end

    # Provisions the supporting service containers (database, cache, browser
    # backend, etc.) declared for +agent_run+'s project and returns the
    # environment variables the workload needs to reach them. Folds
    # Docker-specific service provisioning behind the runner boundary so
    # Temporal activities never instantiate a Docker-specific provisioner
    # directly (RDR-054 Phase 1: activities still exist and call this method
    # individually rather than going through +#provision+, so a service
    # dependency change does not require re-provisioning the primary
    # workload).
    #
    # @param agent_run [AgentRun]
    # @param network [Object] provider-specific network identifier
    # @return [Hash] environment variables for the workload (e.g. DATABASE_URL)
    # @spec CONTAINER-RUNTIME-032
    def provision_services(agent_run:, network:)
      raise NotImplementedError, "#{self.class} must implement ##{__method__}"
    end

    # Tears down the supporting service containers provisioned for
    # +agent_run+ (idempotent; a run with no services provisioned is a
    # no-op). Reference counting for containers shared across runs is the
    # provisioner's responsibility, not the runner's.
    #
    # @param agent_run [AgentRun]
    # @param stale_requeue_count [Integer, nil] override for per-run resource naming
    # @return [void]
    # @spec CONTAINER-RUNTIME-032
    def cleanup_services(agent_run:, stale_requeue_count: nil)
      raise NotImplementedError, "#{self.class} must implement ##{__method__}"
    end

    # Provisions the MCP servers declared on +agent_run+'s
    # +mcp_server_snapshot+: materializes +npx+ definitions as stdio server
    # specs (not Docker-specific — never modeled as a {ServiceDeclaration})
    # and provisions +docker_image+ definitions as sidecar containers on the
    # run's network.
    #
    # @param agent_run [AgentRun]
    # @param network [Object] provider-specific network identifier
    # @return [Hash] +{stdio_servers:, url_servers:}+
    # @spec CONTAINER-RUNTIME-033
    def provision_mcp_servers(agent_run:, network:)
      raise NotImplementedError, "#{self.class} must implement ##{__method__}"
    end

    # Tears down the MCP sidecar containers provisioned for +agent_run+.
    #
    # @param agent_run [AgentRun]
    # @return [void]
    # @spec CONTAINER-RUNTIME-033
    def cleanup_mcp_servers(agent_run:)
      raise NotImplementedError, "#{self.class} must implement ##{__method__}"
    end

    # Provisions the verification browser sidecar (Playwright/Chromium) used
    # by run verification, when the project has verification enabled.
    #
    # @param agent_run [AgentRun]
    # @param network [Object] provider-specific network identifier
    # @param logger [Object] structured logger
    # @return [Object] provisioner-specific result (status, container_id, hostname, cdp_url)
    # @spec CONTAINER-RUNTIME-034
    def provision_browser_container(agent_run:, network:, logger:)
      raise NotImplementedError, "#{self.class} must implement ##{__method__}"
    end

    # Declares the capability set this runner supports on the given backend.
    # Backends can narrow a runner's baseline capability set when the transport
    # already proves a real limitation (for example, a remote Docker backend
    # without host-path mounts).
    #
    # @param backend [Object]
    # @return [CapabilitySet]
    # @spec CONTAINER-RUNTIME-036
    def self.capabilities(backend:)
      raise NotImplementedError, "#{name} must implement .#{__method__}"
    end

    # Provider-neutral capability validation shared by queue-time compatibility
    # checks and direct runner preflight. Logs the mismatch so host placement
    # and fail-fast provision paths surface the same observability signal.
    #
    # @param requirements [CapabilityRequirements]
    # @param backend [Object]
    # @param agent_run [AgentRun, nil]
    # @return [CompatibilityResult]
    # @spec CONTAINER-RUNTIME-038
    # @spec CONTAINER-RUNTIME-039
    def self.capability_compatibility_for(requirements:, backend:, agent_run: nil, log_mismatch: true)
      available = capabilities(backend: backend)
      missing = available.missing(requirements.to_a)
      return CompatibilityResult.new(compatible: true, error_message: nil) if missing.empty?

      if log_mismatch
        Rails.logger.info(
          message: "execution_runners.capability_mismatch",
          agent_run_id: agent_run&.id,
          runner_type: name,
          backend_identifier: backend&.identifier,
          available_capabilities: available.to_a,
          required_capabilities: requirements.to_a,
          missing_capabilities: missing
        )
      end

      CompatibilityResult.new(
        compatible: false,
        error_message: "Runner lacks required capabilities: #{format_capabilities(missing)}."
      )
    end

    # Check compatibility before provisioning (e.g. host-path requirements).
    # Called for every candidate during scheduling, so it must be cheap and
    # must not mutate state or record telemetry.
    #
    # Implementations should also check {.supports_policy?} so a spec whose
    # networking policy the runner cannot implement is rejected here rather
    # than failing during +#provision+.
    #
    # @param spec [RunSpec]
    # @param backend [Object] the backend/runner descriptor to evaluate
    # @return [CompatibilityResult] compatible + error_message
    def self.compatible?(spec:, backend:)
      raise NotImplementedError, "#{name} must implement .#{__method__}"
    end

    # Capability check: does this runner implement the given networking
    # policy intent? A runner that cannot honor a policy returns +false+
    # here so +.compatible?+ can reject the spec before any
    # container/workload is provisioned (RDR-062). The intent is coarse —
    # the runner does not need to support every flavor of every mode, only
    # the named intents its native primitives can express.
    #
    # @param policy [NetworkingPolicy, nil]
    # @return [Boolean]
    # @spec CONTAINER-RUNTIME-028
    def self.supports_policy?(policy)
      raise NotImplementedError, "#{name} must implement .#{__method__}"
    end

    # Returns the per-runtime egress gateway adapter for enforcing the
    # RDR-055 restricted policy (RDR-055 step 5). +nil+ when the runtime
    # cannot enforce the policy — +.compatible?+ rejects such a spec
    # before provisioning rather than letting a container start with no
    # gateway to translate domain-aware HTTP(S) traffic.
    #
    # @return [AgentRuns::EgressPolicy::GatewayAdapters::Base, nil]
    # @spec EGRESS-POLICY-007
    def self.gateway_adapter
      nil
    end

    # Health check the underlying execution platform. Returns true when the
    # platform is reachable and ready to accept a +#provision+ call.
    #
    # @return [Boolean]
    def self.ping
      raise NotImplementedError, "#{name} must implement .#{__method__}"
    end

    def self.format_capabilities(capabilities)
      Array(capabilities).map { |capability| ExecutionRunners.capability_label(capability) }.join(", ")
    end
    private_class_method :format_capabilities
  end
end
