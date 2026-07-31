# frozen_string_literal: true

module Runners
  class PreflightCheck
    # @spec RUNNER-SCHED-005
    # Pinned runs (manual / resume) skip RunnerResolver on first dispatch, so a
    # block-mode time-window restriction would otherwise let them start during a
    # peak-hour window. Failing preflight here closes that gap: the run is
    # rerouted to a healthy alternative (or parked if all runners are blocked),
    # the same enforcement the resolver applies to late-bound auto-pick.
    REASONS = %w[
      circuit_open
      rate_limited
      missing_api_key
      runner_disabled
      runner_discarded
      runner_not_found
      time_window_blocked
    ].freeze

    Result = Struct.new(:pass?, :reason, :runner_id, keyword_init: true)

    def self.call(...)
      new(...).call
    end

    def initialize(runner:, user:)
      @runner = runner
      @user = user
    end

    def call
      return failure("runner_not_found") unless runner

      return failure("runner_discarded") if runner.discarded?

      return failure("runner_disabled") unless runner.enabled_for_agent_runs?

      # @spec RUNNER-SCHED-005 — block-mode time-window guard for pinned runs
      # that bypass RunnerResolver on first dispatch.
      return failure("time_window_blocked") if runner.blocked_by_time_window?

      return failure("missing_api_key") if api_key_runner_without_secret?

      state = runner_state
      if state
        state.check_circuit_recovery!(timeout: circuit_breaker_timeout)
        return failure("circuit_open") if state.circuit_open?
        return failure("rate_limited") if state.rate_limited?
      end

      Result.new(pass?: true, runner_id: runner.id)
    end

    private

    attr_reader :runner, :user

    def failure(reason)
      raise ArgumentError, "unknown preflight reason: #{reason.inspect}" unless REASONS.include?(reason)

      Result.new(pass?: false, reason: reason, runner_id: runner&.id)
    end

    def api_key_runner_without_secret?
      runner.api_key? && runner.effective_api_secret.blank?
    end

    def runner_state
      user.user_setting&.runner_state_for(runner.state_key)
    end

    def circuit_breaker_timeout
      user.user_setting&.circuit_breaker_timeout_seconds ||
        RunnerState::DEFAULT_RECOVERY_TIMEOUT
    end
  end
end
