# frozen_string_literal: true

module CoordinationPolicyEvolution
  class PrepareInputs
    DEFAULT_LOOKBACK_DAYS = 60
    DEFAULT_MIN_DECISIONS = 10
    DEFAULT_SAMPLE_LIMIT = 5
    POLICY_TYPE = DecompositionService::POLICY_TYPE
    POLICY_KEY = DecompositionService::POLICY_KEY
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
        policy: serialize_policy_snapshot,
        prior_versions: prior_versions.map { |version| serialize_policy_version(version) },
        performance: performance_summary,
        sample_successes: serialize_decisions(sample_successes),
        sample_failures: serialize_decisions(sample_failures)
      }
    end

    private

    attr_reader :account, :policy_type, :lookback_days, :min_decisions, :sample_limit

    def serialize_policy_snapshot
      if coordination_policy&.current_version
        serialize_existing_policy
      else
        serialize_bootstrap_policy
      end
    end

    def prior_versions
      return CoordinationPolicyVersion.none unless coordination_policy

      @prior_versions ||= coordination_policy.coordination_policy_versions
        .recent
        .limit(5)
    end

    def scoped_decisions
      @scoped_decisions ||= DecompositionDecision
        .joins(:project)
        .where(projects: { account_id: account.id })
        .where(decision_type: DecompositionDecision::POLICY_OUTCOME_DECISION_TYPES)
        .where(created_at: lookback_days.days.ago..Time.current)
    end

    def successful_decisions
      @successful_decisions ||= scoped_decisions.where.not(outcome: NOOP_OUTCOMES + FAILURE_OUTCOMES)
    end

    def failed_decisions
      @failed_decisions ||= scoped_decisions.where(outcome: FAILURE_OUTCOMES)
    end

    def performance_summary
      decision_count = outcome_counts.values.sum
      failure_count = count_outcomes(FAILURE_OUTCOMES)
      noop_count = count_outcomes(NOOP_OUTCOMES)
      success_count = decision_count - failure_count - noop_count
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
        decision_type_counts: decision_type_counts,
        outcome_counts: outcome_counts,
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
      average = scoped_decisions.pick(Arel.sql("AVG(COALESCE((hints->>'task_count')::numeric, 0))"))
      return nil if average.nil?

      average.to_f.round(2)
    end

    def decision_type_counts
      @decision_type_counts ||= scoped_decisions.group(:decision_type).count
    end

    def outcome_counts
      @outcome_counts ||= scoped_decisions.group(:outcome).count
    end

    def count_outcomes(outcomes)
      outcome_counts.slice(*outcomes).values.sum
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

    def coordination_policy
      @coordination_policy ||= CoordinationPolicy
        .where(account:, policy_type:, policy_key: POLICY_KEY, project_id: nil)
        .includes(:current_version, :coordination_policy_versions)
        .order(Arel.sql("CASE status WHEN 'active' THEN 0 WHEN 'draft' THEN 1 ELSE 2 END"), id: :desc)
        .first
    end

    def current_strategy
      @current_strategy ||= OrchestrationStrategies::Resolve.call(
        strategy_type: DecompositionService::STRATEGY_TYPE,
        account: account
      )
    end

    def serialize_existing_policy
      version = coordination_policy.current_version

      {
        id: coordination_policy.id,
        policy_type: coordination_policy.policy_type,
        policy_key: coordination_policy.policy_key,
        name: coordination_policy.name,
        description: coordination_policy.description,
        status: coordination_policy.status,
        account_id: coordination_policy.account_id,
        project_id: coordination_policy.project_id,
        context_selector: coordination_policy.context_selector,
        source: "coordination_policy",
        version_id: version.id,
        version: version.version,
        version_status: version.status,
        llm_prompt: version.llm_prompt,
        reasoning: version.reasoning,
        metadata: version.metadata,
        rules: version.rules,
        parameters: version.parameters,
        configuration: effective_configuration(version.rules, version.parameters)
      }
    end

    def serialize_bootstrap_policy
      {
        id: coordination_policy&.id,
        policy_type: policy_type,
        policy_key: POLICY_KEY,
        name: "Feature Decomposition",
        description: "Account-level coordination policy for feature decomposition.",
        status: coordination_policy&.status || "draft",
        account_id: account.id,
        project_id: nil,
        context_selector: coordination_policy&.context_selector || {},
        source: bootstrap_source,
        version_id: nil,
        version: nil,
        version_status: nil,
        llm_prompt: nil,
        reasoning: nil,
        metadata: {},
        rules: {},
        parameters: {},
        configuration: bootstrap_configuration
      }
    end

    def bootstrap_source
      current_strategy.present? ? DecompositionService::STRATEGY_TYPE : "defaults"
    end

    def bootstrap_configuration
      return current_strategy.configuration if current_strategy.present?

      OrchestrationStrategies::Defaults.feature_orchestration
    end

    def serialize_policy_version(version)
      {
        id: version.id,
        version: version.version,
        status: version.status,
        activated_at: version.activated_at&.iso8601,
        retired_at: version.retired_at&.iso8601,
        llm_prompt: version.llm_prompt,
        reasoning: version.reasoning,
        metadata: version.metadata,
        rules: version.rules,
        parameters: version.parameters,
        configuration: effective_configuration(version.rules, version.parameters)
      }
    end

    def effective_configuration(rules, parameters)
      OrchestrationStrategies::Defaults.feature_orchestration.deep_dup.tap do |configuration|
        configuration["decomposition"] = configuration.fetch("decomposition", {}).merge(
          extract_decomposition_config(rules),
          extract_decomposition_config(parameters)
        )
      end
    end

    def extract_decomposition_config(payload)
      return {} unless payload.is_a?(Hash)

      decomposition = payload.fetch("decomposition", {})

      {}.tap do |config|
        if decomposition.is_a?(Hash)
          config["enabled"] = decomposition["enabled"] if decomposition.key?("enabled")
          config["min_components_to_decompose"] = decomposition["min_components_to_decompose"] if decomposition.key?("min_components_to_decompose")
          config["max_tasks"] = decomposition["max_tasks"] if decomposition.key?("max_tasks")
          config["layer_order"] = decomposition["layer_order"] if decomposition.key?("layer_order")
        end

        config["enabled"] = payload["enabled"] if payload.key?("enabled")
        config["min_components_to_decompose"] = payload["min_components_to_decompose"] if payload.key?("min_components_to_decompose")
        config["max_tasks"] = payload["max_tasks"] if payload.key?("max_tasks")
        config["layer_order"] = payload["layer_order"] if payload.key?("layer_order")
      end.compact
    end
  end
end
