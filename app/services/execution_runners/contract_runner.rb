# frozen_string_literal: true

module ExecutionRunners
  # In-memory test double that satisfies the {ExecutionRunners::Base}
  # contract. Used by specs to verify that capability checks, lifecycle
  # transitions, and policy translations behave consistently across runners
  # without spinning up real Docker or remote backends (RDR-062).
  #
  # The runner advertises the set of networking intents it supports as a
  # class-level concern ({.supported_modes}). Any policy whose +mode+ is not
  # in the supported set is rejected by {.compatible?} and raises
  # {ProvisionError} from {#provision} — both consult the same source, so a
  # narrowed runner never reports a spec compatible only to fail later at
  # provision time. The base supported set covers all six RDR-062 intents so
  # {ContractRunner} itself behaves like a fully capable runner; specs that
  # need to exercise capability rejection narrow the set through the
  # {.supporting} factory, which returns a subclass — mirroring how a real
  # remote runner pins its supported set in its own class definition.
  #
  # Behavior is configurable per-instance:
  #
  # - +provision_result:+ — the {RunnerHandle} returned from {#provision}
  #   when the spec is compatible. Defaults to a stable handle keyed off
  #   the spec's agent_run id.
  # - +running_result:+ — boolean returned from {#running?}.
  # - +execute_result:+ — {ExecutionResult} returned from {#start}.
  # - +status_result:+ — {ExecutionStatus} returned from {#status}.
  #
  # The runner records calls into +provision_calls+, +start_calls+,
  # +running_calls+, +status_calls+, +reconnect_calls+, +cancel_calls+, and
  # +cleanup_calls+ so specs can assert the runner was exercised the
  # expected number of times with the expected arguments.
  # @spec CONTAINER-RUNTIME-028
  class ContractRunner < Base
    RUNNER_TYPE = :contract

    # Default set of supported modes — the six canonical RDR-062 intents.
    # Legacy aliases remain accepted via +NetworkingPolicy#canonical_mode+.
    # Narrow via {.supporting} for capability-rejection specs.
    DEFAULT_SUPPORTED_MODES = [
      :no_outbound,
      :proxy_only,
      :git_plus_proxy,
      :approved_services,
      :model_direct,
      :explicit_internet
    ].freeze

    attr_reader :provision_calls, :start_calls, :running_calls, :status_calls,
                :reconnect_calls, :cancel_calls, :cleanup_calls

    # Intents this runner class can implement. Class-level so {.compatible?}
    # and {#provision} consult the same source — a runner must never report a
    # spec compatible and then reject it at provision time. A real remote
    # runner overrides this with its own frozen set.
    def self.supported_modes
      DEFAULT_SUPPORTED_MODES
    end

    # Returns a narrowed {ContractRunner} subclass whose class-level
    # capability checks consult +modes+. Specs use this to exercise
    # capability rejection through the standard {.compatible?} / {#provision}
    # signatures, mirroring how a real remote runner would declare a partial
    # supported set in its own class definition.
    def self.supporting(modes)
      narrowed = normalize_supported_modes(modes)
      Class.new(self) do
        define_singleton_method(:supported_modes) { narrowed }
      end
    end

    def self.compatible?(spec:, backend:)
      return CompatibilityResult.new(compatible: false, error_message: "Backend is not supported") if backend.nil?

      if supports_policy?(spec.networking_policy)
        # Restricted policies must be enforceable: a runtime without a
        # gateway adapter cannot honor the RDR-055 domain-aware allowlist,
        # and any adapter present must also answer +capable?+ for this
        # backend (Kubernetes/managed-machine adapters answer +false+ for
        # non-matching backends). The contract runner's default gateway
        # adapter is nil, so narrowed test runners can opt in by
        # overriding {.gateway_adapter} to return a real adapter.
        # @spec EGRESS-POLICY-007
        if policy_requires_egress_gateway?(spec.networking_policy) && !egress_capable?(spec: spec, backend: backend)
          return CompatibilityResult.new(
            compatible: false,
            error_message: "Runtime cannot enforce the egress policy snapshot on this backend; register a capable gateway adapter or reject the run"
          )
        end

        CompatibilityResult.new(compatible: true, error_message: nil)
      else
        CompatibilityResult.new(
          compatible: false,
          error_message: unsupported_policy_message(spec.networking_policy)
        )
      end
    end

    # Returns true when the registered gateway adapter can enforce the
    # restricted policy on +backend+. Mirrors {LocalDockerRunner}: the
    # runner must have an adapter, and the adapter must answer +true+
    # from {GatewayAdapters::Base#capable?}. Used by {.compatible?} so
    # narrowing the registered adapter or stubbing +capable?+ exercises
    # the same code path production runners use.
    # @spec EGRESS-POLICY-007
    def self.egress_capable?(spec:, backend:)
      adapter = gateway_adapter
      return false if adapter.nil?

      snapshot = AgentRuns::EgressPolicy::Snapshot.from_record(spec.agent_run)
      adapter.capable?(snapshot: snapshot, backend: backend)
    end

    # Single source for the unsupported-policy error message, shared by
    # {.compatible?} (rejects before scheduling) and {#provision} (rejects
    # before any side effect). Mirrors {LocalDockerRunner}.
    def self.unsupported_policy_message(policy)
      "Runner does not support networking policy #{policy&.mode.inspect}"
    end

    # Capability check: the contract runner only honors policies whose mode
    # appears in {.supported_modes}. A real remote runner derives its
    # supported set from the platform's egress primitives (RDR-062). A +nil+
    # policy is always rejected — there is no networking intent to honor.
    # @spec CONTAINER-RUNTIME-028
    def self.supports_policy?(policy)
      return false if policy.nil?

      supported_modes.include?(policy.mode) || supported_modes.include?(policy.canonical_mode)
    end

    def self.policy_requires_egress_gateway?(policy)
      policy.present? && policy.restricted? && !policy.no_outbound? && policy.mode != :proxy_only
    end

    def self.ping
      true
    end

    def self.normalize_supported_modes(modes)
      narrowed = Array(modes).map(&:to_sym)
      unknown = narrowed - ExecutionRunners::NETWORKING_POLICY_KNOWN_MODES
      raise ArgumentError, "Unknown networking policy modes: #{unknown.inspect}" if unknown.any?

      narrowed.freeze
    end
    private_class_method :normalize_supported_modes

    def initialize(provision_result: nil,
                   running_result: true,
                   execute_result: nil,
                   status_result: nil)
      super()
      @provision_calls = []
      @start_calls = []
      @running_calls = []
      @status_calls = []
      @reconnect_calls = []
      @cancel_calls = []
      @cleanup_calls = []
      @default_provision_result = provision_result
      @running_result = running_result
      @execute_result = execute_result
      @status_result = status_result
    end

    def supported_modes
      self.class.supported_modes
    end

    def provision(spec:)
      @provision_calls << spec
      unless self.class.supports_policy?(spec.networking_policy)
        raise ProvisionError, self.class.unsupported_policy_message(spec.networking_policy)
      end

      # Mirror .compatible?'s restricted-policy guard so a spec that would be
      # rejected before scheduling cannot still be provisioned directly
      # against this runner (#3556 review). The contract runner has no real
      # backend of its own (it is an in-memory double), so it checks
      # enforceability the same way .compatible? does for a nil backend —
      # any adapter that requires a specific backend to answer +capable?+
      # opts in via {.supporting}/{.gateway_adapter} stubbing, same as specs
      # exercising .compatible? do.
      # @spec EGRESS-POLICY-007
      if self.class.policy_requires_egress_gateway?(spec.networking_policy) &&
          !self.class.egress_capable?(spec: spec, backend: nil)
        raise ProvisionError,
          "Runtime cannot enforce the egress policy snapshot on this backend; register a capable gateway adapter or reject the run"
      end

      default_handle_for(spec)
    end

    def start(handle:, command:, timeout: nil, startup_timeout: nil, idle_timeout: nil,
              abort_patterns: nil, preparation: nil, heartbeat_path: nil)
      @start_calls << { handle: handle, command: command, timeout: timeout }
      @execute_result || ExecutionResult.success(stdout: "ok", exit_code: 0)
    end

    def running?(handle:)
      @running_calls << handle
      @running_result
    end

    # The contract runner keeps no external state, so the reconnected
    # "service" is the runner itself — lifecycle calls continue to work from
    # the handle without a real platform round-trip.
    def reconnect(handle:)
      @reconnect_calls << handle
      self
    end

    def status(handle:)
      @status_calls << handle
      @status_result || ExecutionStatus.not_found
    end

    def cancel(handle:)
      @cancel_calls << handle
      nil
    end

    def cleanup(handle:, force: false)
      @cleanup_calls << { handle: handle, force: force }
      nil
    end

    private

    def default_handle_for(spec)
      return @default_provision_result if @default_provision_result

      RunnerHandle.new(
        runner_type: RUNNER_TYPE,
        identifier: "contract-#{spec.agent_run&.id}",
        host: "contract",
        workspace_ref: "contract-#{spec.agent_run&.id}",
        metadata: { "agent_run_id" => spec.agent_run&.id }
      )
    end
  end
end
