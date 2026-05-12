# frozen_string_literal: true

module Workflows
  class CoordinationPolicyEvolutionWorkflow < BaseWorkflow
    MUTATION_TIMEOUT = 120

    def execute(input)
      account_id = input.fetch(:account_id)
      policy_type = input.fetch(:policy_type, CoordinationPolicyEvolution::PrepareInputs::POLICY_TYPE)

      inputs_result = run_activity(
        Activities::PrepareCoordinationPolicyEvolutionInputsActivity,
        {
          account_id: account_id,
          policy_type: policy_type,
          lookback_days: input.fetch(:lookback_days, CoordinationPolicyEvolution::PrepareInputs::DEFAULT_LOOKBACK_DAYS),
          min_decisions: input.fetch(:min_decisions, CoordinationPolicyEvolution::PrepareInputs::DEFAULT_MIN_DECISIONS),
          sample_limit: input.fetch(:sample_limit, CoordinationPolicyEvolution::PrepareInputs::DEFAULT_SAMPLE_LIMIT)
        },
        timeout: 30
      )

      performance = inputs_result.fetch(:performance, {})
      decision_count = performance.fetch(:decision_count, 0)
      classified_decision_count = performance.fetch(:classified_decision_count, decision_count)
      min_decisions = performance.fetch(:min_decisions, CoordinationPolicyEvolution::PrepareInputs::DEFAULT_MIN_DECISIONS)

      if classified_decision_count < min_decisions
        return {
          status: :insufficient_history,
          account_id: account_id,
          policy_type: policy_type,
          decision_count: decision_count,
          classified_decision_count: classified_decision_count,
          min_decisions: min_decisions
        }
      end

      mutation_result = run_activity(
        Activities::GenerateCoordinationPolicyCandidatesActivity,
        inputs_result.merge(
          mutation_count: input.fetch(:mutation_count, 2),
          strategies: input[:strategies]
        ),
        timeout: MUTATION_TIMEOUT
      )

      mutations = mutation_result.fetch(:mutations, [])
      if mutations.blank?
        return {
          status: :no_candidates,
          account_id: account_id,
          policy_type: policy_type
        }
      end

      persist_result = run_activity(
        Activities::PersistCoordinationPolicyCandidatesActivity,
        {
          account_id: account_id,
          policy: inputs_result.fetch(:policy),
          mutations: mutations
        },
        timeout: 30
      )

      candidate_ids = persist_result.fetch(:candidate_ids, [])
      if candidate_ids.blank?
        return {
          status: :no_candidates_created,
          account_id: account_id,
          policy_type: policy_type
        }
      end

      {
        status: :candidates_created,
        account_id: account_id,
        policy_type: policy_type,
        candidate_ids: candidate_ids,
        candidate_count: persist_result.fetch(:candidate_count, candidate_ids.size)
      }
    end
  end
end
