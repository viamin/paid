# frozen_string_literal: true

# @spec FEATURE-APPROVAL-006
class AddCriteriaClarityToFeatureIntents < ActiveRecord::Migration[8.1]
  def change
    add_column :feature_intents, :criteria_clarity_state, :string, null: false, default: "pending",
      comment: "Cached AI clarity judgment for acceptance criteria: pending, clear, or vague. Computed by FeatureIntents::EvaluateCriteriaClarity, not on Inbox render, so listing entries never makes a live LLM call per feature."
    add_column :feature_intents, :criteria_clarity_explanation, :text, comment: "Human-facing explanation of the criteria_clarity_state verdict."
    add_column :feature_intents, :criteria_clarity_evaluated_at, :datetime, comment: "When criteria_clarity_state was last computed."
  end
end
