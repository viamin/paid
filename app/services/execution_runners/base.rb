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
    def start(handle:, command:, timeout:, startup_timeout:, idle_timeout:,
              abort_patterns:, preparation:, heartbeat_path:)
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
    # @spec CONTAINER-RUNTIME-018
    def self.supports_policy?(policy)
      raise NotImplementedError, "#{name} must implement .#{__method__}"
    end

    # Health check the underlying execution platform. Returns true when the
    # platform is reachable and ready to accept a +#provision+ call.
    #
    # @return [Boolean]
    def self.ping
      raise NotImplementedError, "#{name} must implement .#{__method__}"
    end
  end
end
