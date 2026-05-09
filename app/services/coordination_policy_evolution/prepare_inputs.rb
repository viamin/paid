# frozen_string_literal: true

module CoordinationPolicyEvolution
  class PrepareInputs
    DEFAULT_LOOKBACK_DAYS = 60
    DEFAULT_MIN_DECISIONS = 10
    DEFAULT_SAMPLE_LIMIT = 5
    POLICY_TYPE = Coordination::DecompositionService::STRATEGY_TYPE
    NOOP_OUTCOMES = Orchestration::DecompositionDecisions::Log::NOOP_OUTCOMES
    FAILURE_OUTCOMES = %w[
      decomposition_failed
      sub_issue_creation_failed
      planning_failed
      parallelization_planning_failed
      parallelization_failed
    ].freeze

    def self.call(...)
      new(...).call
    end

    def initialize(account:, policy_type: POLICY_TYPE, lookback_days: DEFAULT_LOOKBACK_DAYS,
      min_decisions: DEFAULT_MIN_DECISIONS, sample_limit: DEFAULT_SAMPLE_LIMIT)
      @account = account
      @policy_type = policy_type.to_s
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

    attr_reader :account, :policy_type, :lookback_days, :min_decisions, :sample_limit

    def current_strategy
      @current_strategy ||= OrchestrationStrategies::Resolve.call(
        strategy_type: policy_type,
        account: account
      )
    end

    def prior_versions
      @prior_versions ||= OrchestrationStrategy
        .where(account:, strategy_type: policy_type)
        .order(version: :desc, id: :desc)
        .limit(5)
    end

    def scoped_decisions
      @scoped_decisions ||= DecompositionDecision
        .joins(:project)
        .where(projects: { account_id: account.id })
        .where(created_at: lookback_days.days.ago..Time.current)
    end

    def aggregates
      @aggregates ||= scoped_decisions.pick(
        Arel.sql("COUNT(*)"),
        Arel.sql("COUNT(*) FILTER (WHERE outcome NOT IN ('#{noop_and_failure_outcomes_sql}'))"),
        Arel.sql("COUNT(*) FILTER (WHERE outcome IN ('#{FAILURE_OUTCOMES.join("','")}'))"),
        Arel.sql("COUNT(*) FILTER (WHERE outcome IN ('#{NOOP_OUTCOMES.join("','")}'))"),
        Arel.sql("AVG(COALESCE((hints->>'task_count')::numeric, 0))")
      )
    end

    def successful_decisions
      @successful_decisions ||= scoped_decisions.where.not(outcome: NOOP_OUTCOMES + FAILURE_OUTCOMES)
    end

    def failed_decisions
      @failed_decisions ||= scoped_decisions.where(outcome: FAILURE_OUTCOMES)
    end

    def performance_summary
      decision_count = aggregates[0]
      success_count = aggregates[1]
      failure_count = aggregates[2]
      noop_count = aggregates[3]
      classified_decision_count = success_count + failure_count

      {
        decision_count: decision_count,
        classified_decision_count: classified_decision_count,
        min_decisions: min_decisions,
        success_count: success_count,
        failure_count: failure_count,
        noop_count: noop_count,
        success_rate: success_rate(classified_decision_count, success_count),
        lookback_days: lookback_days,
        decision_type_counts: scoped_decisions.group(:decision_type).count,
        outcome_counts: scoped_decisions.group(:outcome).count,
        policy_source_counts: policy_source_counts,
        average_task_count: average_task_count
      }
    end

    def sample_successes
      @sample_successes ||= successful_decisions.order(created_at: :desc, id: :desc).limit(sample_limit)
    end

    def sample_failures
      @sample_failures ||= failed_decisions.order(created_at: :desc, id: :desc).limit(sample_limit)
    end

    def success_rate(classified_decision_count, success_count)
      return nil if classified_decision_count.zero?

      (success_count.to_f / classified_decision_count).round(4)
    end

    def policy_source_counts
      scoped_decisions
        .group(Arel.sql("COALESCE(metadata->>'policy_source', 'unknown')"))
        .count
    end

    def average_task_count
      average = aggregates[4]
      return nil if average.nil?

      average.to_f.round(2)
    end

    def noop_and_failure_outcomes_sql
      (NOOP_OUTCOMES + FAILURE_OUTCOMES).join("','")
    end

    def serialize_decisions(rows)
      rows.map do |decision|
        {
          id: decision.id,
          decision_key: decision.decision_key,
          decision_type: decision.decision_type,
          outcome: decision.outcome,
          created_at: decision.created_at.iso8601,
          workflow_name: decision.workflow_name,
          workflow_id: decision.workflow_id,
          input_context: decision.input_context,
          hints: decision.hints,
          error_details: decision.error_details,
          metadata: decision.metadata
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
  end
end
