# frozen_string_literal: true

module StrategyEvolution
  class PrepareInputs
    DEFAULT_LOOKBACK_DAYS = 60
    DEFAULT_MIN_DECISIONS = 10
    DEFAULT_SAMPLE_LIMIT = 5
    SUCCESSFUL_RUN_STATUSES = %w[completed no_output].freeze

    def self.call(...)
      new(...).call
    end

    def initialize(strategy_type:, account:, lookback_days: DEFAULT_LOOKBACK_DAYS,
      min_decisions: DEFAULT_MIN_DECISIONS, sample_limit: DEFAULT_SAMPLE_LIMIT)
      @strategy_type = strategy_type.to_s
      @account = account
      @lookback_days = lookback_days
      @min_decisions = min_decisions
      @sample_limit = sample_limit
    end

    def call
      {
        strategy: serialize_strategy(current_strategy),
        prior_versions: prior_versions.map { |strategy| serialize_strategy(strategy) },
        performance: performance_summary,
        sample_successes: sampled_decisions(successes),
        sample_failures: sampled_decisions(failures)
      }
    end

    private

    attr_reader :strategy_type, :account, :lookback_days, :min_decisions, :sample_limit

    def current_strategy
      @current_strategy ||= OrchestrationStrategy.active_for(strategy_type, account: account) ||
        OrchestrationStrategies::Resolve.call(strategy_type:, account:)
    end

    def prior_versions
      @prior_versions ||= OrchestrationStrategy
        .where(account:, strategy_type:)
        .order(version: :desc, id: :desc)
        .limit(5)
    end

    def decisions
      @decisions ||= OrchestrationDecision
        .includes(:agent_run)
        .joins(:project)
        .where(projects: { account_id: account.id })
        .where(created_at: lookback_days.days.ago..Time.current)
        .order(created_at: :desc, id: :desc)
        .to_a
    end

    def performance_summary
      run_backed = decisions.count { |decision| decision.agent_run.present? }
      successful = successes.count
      failed = failures.count

      {
        decision_count: decisions.size,
        min_decisions: min_decisions,
        run_backed_decision_count: run_backed,
        success_count: successful,
        failure_count: failed,
        success_rate: success_rate(run_backed, successful),
        decision_types: tally(decisions.map(&:decision_type)),
        actors: tally(decisions.map(&:actor)),
        run_statuses: tally(decisions.filter_map { |decision| decision.agent_run&.status }),
        guardrail_violation_types: tally(decisions.filter_map { |decision| decision.agent_run&.guardrail_violation_type })
      }
    end

    def successes
      decisions.select { |decision| successful_run?(decision) }
    end

    def failures
      decisions.select { |decision| failed_run?(decision) }
    end

    def successful_run?(decision)
      SUCCESSFUL_RUN_STATUSES.include?(decision.agent_run&.status)
    end

    def failed_run?(decision)
      decision.agent_run&.guardrail_violation_type.present? ||
        (decision.agent_run.present? && !successful_run?(decision))
    end

    def success_rate(run_backed, successful)
      return nil if run_backed.zero?

      (successful.to_f / run_backed).round(4)
    end

    def sampled_decisions(rows)
      rows.first(sample_limit).map do |decision|
        {
          id: decision.id,
          decision_type: decision.decision_type,
          actor: decision.actor,
          created_at: decision.created_at.iso8601,
          run_status: decision.agent_run&.status,
          guardrail_violation_type: decision.agent_run&.guardrail_violation_type,
          context: decision.context,
          inputs: decision.inputs,
          outputs: decision.outputs
        }
      end
    end

    def serialize_strategy(strategy)
      return nil unless strategy

      {
        id: strategy.id,
        strategy_type: strategy.strategy_type,
        name: strategy.name,
        version: strategy.version,
        active: strategy.active,
        account_id: strategy.account_id,
        configuration: strategy.configuration
      }
    end

    def tally(values)
      values.reject(&:blank?).tally
    end
  end
end
