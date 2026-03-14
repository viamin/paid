# frozen_string_literal: true

FactoryBot.define do
  factory :model_selection do
    agent_run
    llm_model
    selector_type { "rules" }
    reasoning { "Selected based on complexity analysis" }
    candidates { [ { model_id: "test-model", score: 8.0 } ] }
  end
end
