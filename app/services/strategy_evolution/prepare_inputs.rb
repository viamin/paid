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
        sample_successes: serialize_decisions(sample_successes),
        sample_failures: serialize_decisions(sample_failures)
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

    def scoped_decisions
      OrchestrationDecision
        .joins(:project)
        .where(projects: { account_id: account.id })
        .where(created_at: lookback_days.days.ago..Time.current)
    end

    def aggregates
      @aggregates ||= scoped_decisions
        .left_joins(:agent_run)
        .pick(
          Arel.sql("COUNT(*)"),
          Arel.sql("COUNT(agent_runs.id)"),
          Arel.sql("COUNT(*) FILTER (WHERE agent_runs.status IN ('completed','no_output'))"),
          Arel.sql("COUNT(*) FILTER (WHERE agent_runs.guardrail_violation_type IS NOT NULL " \
                   "OR (agent_runs.id IS NOT NULL AND agent_runs.status NOT IN ('completed','no_output')))")
        )
    end

    def decision_count
      aggregates[0]
    end

    def run_backed_count
      aggregates[1]
    end

    def success_count
      aggregates[2]
    end

    def failure_count
      aggregates[3]
    end

    def tallies
      @tallies ||= begin
        base = scoped_decisions.left_joins(:agent_run)
        {
          decision_types: tally_column(base, "orchestration_decisions.decision_type"),
          actors: tally_column(base, "orchestration_decisions.actor"),
          run_statuses: tally_column(base, "agent_runs.status"),
          guardrail_violation_types: tally_column(base, "agent_runs.guardrail_violation_type")
        }
      end
    end

    def performance_summary
      {
        decision_count: decision_count,
        min_decisions: min_decisions,
        run_backed_decision_count: run_backed_count,
        success_count: success_count,
        failure_count: failure_count,
        success_rate: success_rate(run_backed_count, success_count),
        **tallies
      }
    end

    def sample_successes
      @sample_successes ||= scoped_decisions
        .includes(:agent_run)
        .joins(:agent_run)
        .where(agent_runs: { status: SUCCESSFUL_RUN_STATUSES })
        .order(created_at: :desc, id: :desc)
        .limit(sample_limit)
    end

    def sample_failures
      @sample_failures ||= scoped_decisions
        .includes(:agent_run)
        .joins(:agent_run)
        .where(
          "agent_runs.guardrail_violation_type IS NOT NULL " \
          "OR agent_runs.status NOT IN (?)", SUCCESSFUL_RUN_STATUSES
        )
        .order(created_at: :desc, id: :desc)
        .limit(sample_limit)
    end

    def success_rate(run_backed, successful)
      return nil if run_backed.zero?

      (successful.to_f / run_backed).round(4)
    end

    def serialize_decisions(rows)
      rows.map do |decision|
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

    def tally_column(relation, column)
      relation
        .where.not(column => [ nil, "" ])
        .group(column)
        .count
    end
  end
end
