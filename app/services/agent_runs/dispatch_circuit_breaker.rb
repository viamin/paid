# frozen_string_literal: true

module AgentRuns
  class DispatchCircuitBreaker
    def self.halted?(account)
      new(account).halted?
    end

    def self.record_outcome!(account:, runner_name:, success:)
      new(account).record_outcome!(runner_name: runner_name, success: success)
    end

    def self.evaluate!(account)
      new(account).evaluate!
    end

    def self.probe_decision(account)
      new(account).probe_decision
    end

    def initialize(account)
      @account = account
    end

    def halted?
      return false unless enabled?

      breaker = breaker_record
      return false unless breaker&.persisted?
      return false if breaker.circuit_closed?

      breaker.check_recovery! if breaker.circuit_open?
      breaker.halted?
    end

    # Returns a probe decision for the dispatch loop:
    #   :allow_probe  — half_open and a probe run should be dispatched (and recorded as such)
    #   :dispatch     — closed (no halt, dispatch normally)
    #   :halt         — open/half_open with no probe allowed
    def probe_decision
      return :dispatch unless enabled?

      breaker = breaker_record
      return :dispatch unless breaker&.persisted?
      return :dispatch if breaker.circuit_closed?

      breaker.check_recovery! if breaker.circuit_open?
      breaker.probe_allowed? ? :allow_probe : :halt
    end

    def mark_probe_dispatched!
      breaker = breaker_record
      return unless breaker&.persisted?

      breaker.mark_probe_dispatched!
    end

    def record_outcome!(runner_name:, success:)
      return unless enabled?

      breaker = breaker_record!

      if breaker.circuit_half_open?
        if success
          breaker.record_half_open_success!
        else
          breaker.record_half_open_failure!
        end
      elsif breaker.circuit_closed? && breaker.evaluation_due?
        evaluate!
      end
    end

    def evaluate!
      return unless enabled?

      breaker = breaker_record!
      return unless breaker.circuit_closed?
      return unless breaker.evaluation_due?

      stats = provider_failure_stats
      breaker.record_evaluation!

      return unless all_providers_failing?(stats)

      breaker.trip!(metadata: {
        failure_rate: stats[:overall_failure_rate],
        providers: stats[:providers],
        window_minutes: window_minutes,
        total_runs: stats[:total_runs],
        total_failures: stats[:total_failures],
        evaluated_at: Time.current.iso8601
      })
    end

    private

    attr_reader :account

    def breaker_record
      ::DispatchCircuitBreaker.for_account(account)
    end

    def breaker_record!
      record = breaker_record
      return record if record.persisted?

      record.save!
      record
    rescue ActiveRecord::RecordNotUnique
      ::DispatchCircuitBreaker.for_account!(account)
    end

    def enabled?
      settings = account.tenant_setting
      enabled = settings&.effective_agent_settings&.dig("dispatch_circuit_breaker_enabled")
      enabled.nil? || enabled == true
    end

    def failure_rate_threshold
      settings = account.tenant_setting
      threshold = settings&.effective_agent_settings&.dig("dispatch_circuit_breaker_failure_rate_threshold")
      (threshold || ::DispatchCircuitBreaker::DEFAULT_FAILURE_RATE_THRESHOLD).to_f
    end

    def window_minutes
      settings = account.tenant_setting
      (settings&.effective_agent_settings&.dig("dispatch_circuit_breaker_window_minutes") ||
        ::DispatchCircuitBreaker::DEFAULT_WINDOW_MINUTES).to_i
    end

    def min_runs
      settings = account.tenant_setting
      (settings&.effective_agent_settings&.dig("dispatch_circuit_breaker_min_runs") ||
        ::DispatchCircuitBreaker::DEFAULT_MIN_RUNS).to_i
    end

    PROVIDER_OUTCOME_STATUSES = (AgentRun::FAILURE_STATUSES + %w[completed no_output]).freeze

    def provider_failure_stats
      since = window_minutes.minutes.ago
      failure_filter = AgentRun.sanitize_sql_array(
        [ "status IN (?)", AgentRun::FAILURE_STATUSES ]
      )

      runs = AgentRun.joins(:project)
        .where(projects: { account_id: account.id })
        .where.not(final_runner: [ nil, "" ])
        .where(completed_at: since..)
        .where(status: PROVIDER_OUTCOME_STATUSES)
        .group(:final_runner)
        .select(
          <<~SQL.squish
            final_runner,
            COUNT(*) AS total_count,
            COUNT(*) FILTER (WHERE #{failure_filter}) AS failure_count
          SQL
        )

      active_runner_keys = active_runner_keys_for_account
      runner_key_by_id = active_runner_keys_by_id
      providers_by_runner_key = {}
      total_runs = 0
      total_failures = 0

      runs.each do |run|
        total = run[:total_count].to_i
        failures = run[:failure_count].to_i
        total_runs += total
        total_failures += failures

        runner_key = resolve_runner_key(run.final_runner, runner_key_by_id: runner_key_by_id,
          active_runner_keys: active_runner_keys)
        next if runner_key.blank?

        existing = providers_by_runner_key[runner_key] || { total: 0, failures: 0 }
        existing[:total] += total
        existing[:failures] += failures
        providers_by_runner_key[runner_key] = existing
      end

      providers = providers_by_runner_key.transform_values do |provider_stats|
        total = provider_stats[:total]
        failures = provider_stats[:failures]
        {
          total: total,
          failures: failures,
          failure_rate: total > 0 ? failures.to_f / total : 0.0
        }
      end

      {
        providers: providers,
        active_runner_keys: active_runner_keys,
        total_runs: total_runs,
        total_failures: total_failures,
        overall_failure_rate: total_runs > 0 ? total_failures.to_f / total_runs : 0.0
      }
    end

    def all_providers_failing?(stats)
      active_runner_keys = stats[:active_runner_keys] || []
      return false if active_runner_keys.empty?
      return false if stats[:total_runs] < min_runs

      observed_keys = stats[:providers].keys
      return false unless active_runner_keys.all? { |key| observed_keys.include?(key) }

      stats[:providers].all? do |runner_key, provider_stats|
        next false unless active_runner_keys.include?(runner_key)

        provider_stats[:failure_rate] >= failure_rate_threshold
      end
    end

    # The set of runner_keys currently enabled for agent runs across the
    # account's users. Used to require evidence for every active provider
    # before tripping the account-wide breaker.
    def active_runner_keys_for_account
      Runner.kept_only.for_agent_runs
        .joins(:user)
        .where(users: { account_id: account.id })
        .distinct
        .pluck(:runner_key)
        .compact
        .reject(&:blank?)
        .uniq
    end

    def active_runner_keys_by_id
      Runner.kept_only.for_agent_runs
        .joins(:user)
        .where(users: { account_id: account.id })
        .pluck(:id, :runner_key)
        .to_h
    end

    def resolve_runner_key(identifier, runner_key_by_id:, active_runner_keys:)
      if Runner.routing_key?(identifier)
        runner_key_by_id[Runner.id_from_routing_key(identifier)]
      elsif active_runner_keys.include?(identifier)
        identifier
      else
        # Legacy AgentRun.final_runner values may hold the agent_type
        # (e.g. "claude_code") rather than a runner_key (e.g. "claude").
        # Normalize through RunnerSupport so the breaker can still reason
        # about which provider the run ultimately completed on.
        normalized = RunnerSupport.runner_key_for_agent_type(identifier)
        return nil if normalized == identifier
        return nil unless active_runner_keys.include?(normalized)

        normalized
      end
    end
  end
end
