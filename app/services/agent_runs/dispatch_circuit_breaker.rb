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

    def provider_failure_stats
      since = window_minutes.minutes.ago
      failure_filter = AgentRun.sanitize_sql_array(
        [ "status IN (?)", AgentRun::FAILURE_STATUSES ]
      )

      runs = AgentRun.joins(:project)
        .where(projects: { account_id: account.id })
        .where.not(final_runner: [ nil, "" ])
        .where(completed_at: since..)
        .where(status: AgentRun::FINISHED_STATUSES)
        .group(:final_runner)
        .select(
          <<~SQL.squish
            final_runner,
            COUNT(*) AS total_count,
            COUNT(*) FILTER (WHERE #{failure_filter}) AS failure_count
          SQL
        )

      providers = {}
      total_runs = 0
      total_failures = 0

      runs.each do |run|
        total = run[:total_count].to_i
        failures = run[:failure_count].to_i
        total_runs += total
        total_failures += failures

        providers[run.final_runner] = {
          total: total,
          failures: failures,
          failure_rate: total > 0 ? failures.to_f / total : 0.0
        }
      end

      {
        providers: providers,
        total_runs: total_runs,
        total_failures: total_failures,
        overall_failure_rate: total_runs > 0 ? total_failures.to_f / total_runs : 0.0
      }
    end

    def all_providers_failing?(stats)
      return false if stats[:total_runs] < min_runs
      return false if stats[:providers].empty?

      stats[:providers].all? do |_runner, provider_stats|
        provider_stats[:failure_rate] >= failure_rate_threshold
      end
    end
  end
end
