# frozen_string_literal: true

module Workflows
  class StrategyEvolutionWorkflow < BaseWorkflow
    MUTATION_TIMEOUT = 120

    def execute(input)
      account_id = input.fetch(:account_id)
      strategy_type = input.fetch(:strategy_type)

      inputs_result = run_activity(
        Activities::PrepareStrategyEvolutionInputsActivity,
        {
          account_id: account_id,
          strategy_type: strategy_type,
          lookback_days: input.fetch(:lookback_days, StrategyEvolution::PrepareInputs::DEFAULT_LOOKBACK_DAYS),
          min_decisions: input.fetch(:min_decisions, StrategyEvolution::PrepareInputs::DEFAULT_MIN_DECISIONS),
          sample_limit: input.fetch(:sample_limit, StrategyEvolution::PrepareInputs::DEFAULT_SAMPLE_LIMIT)
        },
        timeout: 30
      )

      performance = inputs_result.fetch(:performance, {})
      decision_count = performance.fetch(:decision_count, 0)
      min_decisions = performance.fetch(:min_decisions, StrategyEvolution::PrepareInputs::DEFAULT_MIN_DECISIONS)

      if decision_count < min_decisions
        return {
          status: :insufficient_history,
          account_id: account_id,
          strategy_type: strategy_type,
          decision_count: decision_count,
          min_decisions: min_decisions
        }
      end

      mutation_result = run_activity(
        Activities::GenerateStrategyMutationsActivity,
        inputs_result.merge(
          mutation_count: input.fetch(:mutation_count, 2),
          strategies: input[:strategies]
        ),
        timeout: MUTATION_TIMEOUT
      )

      mutations = mutation_result.fetch(:mutations, [])
      if mutations.blank?
        return {
          status: :no_mutations,
          account_id: account_id,
          strategy_type: strategy_type
        }
      end

      persist_result = run_activity(
        Activities::PersistStrategyCandidatesActivity,
        {
          account_id: account_id,
          strategy: inputs_result.fetch(:strategy),
          mutations: mutations
        },
        timeout: 30
      )

      candidate_ids = persist_result.fetch(:candidate_ids, [])
      if candidate_ids.blank?
        return {
          status: :no_candidates_created,
          account_id: account_id,
          strategy_type: strategy_type
        }
      end

      experiment_result = run_activity(
        Activities::CreateEvolutionStrategyExperimentActivity,
        {
          account_id: account_id,
          strategy: inputs_result.fetch(:strategy),
          candidate_ids: candidate_ids,
          min_samples_per_variant: input.fetch(:min_samples_per_variant, 30),
          confidence_threshold: input.fetch(:confidence_threshold, 0.95),
          traffic_percentage: input.fetch(:traffic_percentage, 100)
        },
        timeout: 30
      )

      {
        status: :candidates_created,
        account_id: account_id,
        strategy_type: strategy_type,
        candidate_ids: candidate_ids,
        candidate_count: persist_result.fetch(:candidate_count, candidate_ids.size),
        strategy_experiment_id: experiment_result[:strategy_experiment_id],
        experiment_status: experiment_result[:status]
      }
    end
  end
end
