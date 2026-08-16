# frozen_string_literal: true

module ExecutionRunners
  # In-memory test double that satisfies the {ExecutionRunners::Base}
  # contract. Used by specs to verify that capability checks, lifecycle
  # transitions, and policy translations behave consistently across runners
  # without spinning up real Docker or remote backends (RDR-062).
  #
  # The runner advertises the set of networking intents it supports via the
  # +supports:+ keyword (a list of policy mode symbols). Any policy whose
  # +mode+ is not in the supported set is rejected by {.compatible?} and
  # raises {ProvisionError} from {#provision}. The default supported set
  # covers all six RDR-062 intents so a fresh instance behaves like a fully
  # capable runner; specs that need to exercise capability rejection pass
  # a smaller set via +supports:+.
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
  # @spec CONTAINER-RUNTIME-018
  class ContractRunner < Base
    RUNNER_TYPE = :contract

    # Default set of supported modes — the six canonical RDR-062 intents.
    # Legacy aliases remain accepted via +NetworkingPolicy#canonical_mode+.
    # Use +supports:+ to narrow this for capability-rejection specs.
    DEFAULT_SUPPORTED_MODES = [
      :no_outbound,
      :proxy_only,
      :git_plus_proxy,
      :approved_services,
      :model_direct,
      :explicit_internet
    ].freeze

    attr_reader :provision_calls, :start_calls, :running_calls, :status_calls,
                :reconnect_calls, :cancel_calls, :cleanup_calls, :supported_modes

    def initialize(supports: nil,
                   provision_result: nil,
                   running_result: true,
                   execute_result: nil,
                   status_result: nil)
      super()
      @supported_modes = Array(supports || DEFAULT_SUPPORTED_MODES).map(&:to_sym).freeze
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

    def provision(spec:)
      @provision_calls << spec
      unless self.class.supports_policy?(spec.networking_policy, supported_modes: @supported_modes)
        raise ProvisionError,
              "Networking policy #{spec.networking_policy&.mode.inspect} is not supported"
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

    def self.compatible?(spec:, backend:, supported_modes: nil)
      return CompatibilityResult.new(compatible: false, error_message: "Backend is not supported") if backend.nil?

      modes = supported_modes || DEFAULT_SUPPORTED_MODES
      if supports_policy?(spec.networking_policy, supported_modes: modes)
        CompatibilityResult.new(compatible: true, error_message: nil)
      else
        CompatibilityResult.new(
          compatible: false,
          error_message: "Networking policy #{spec.networking_policy&.mode.inspect} is not supported by #{name}"
        )
      end
    end

    # Capability check: the contract runner only honors policies whose mode
    # appears in the supplied supported_modes list. A real remote runner
    # would derive its supported set from the platform's egress primitives
    # (RDR-062). A +nil+ policy is always rejected — there is no networking
    # intent to honor.
    def self.supports_policy?(policy, supported_modes: nil)
      return false if policy.nil?

      modes = supported_modes || DEFAULT_SUPPORTED_MODES
      modes.include?(policy.mode) || modes.include?(policy.canonical_mode)
    end

    def self.ping
      true
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
