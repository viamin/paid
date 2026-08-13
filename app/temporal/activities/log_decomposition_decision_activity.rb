# frozen_string_literal: true

module Activities
  class LogDecompositionDecisionActivity < BaseActivity
    activity_name "LogDecompositionDecision"

    def execute(input)
      decision = Orchestration::DecompositionDecisions::Log.call(**input.deep_symbolize_keys)

      {
        decomposition_decision_id: decision.id,
        decision_key: decision.decision_key
      }
    end
  end
end
