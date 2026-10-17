# frozen_string_literal: true

class CreateTriggerLogidzeOnFeatureIntentIssuePrerequisiteMappings < ActiveRecord::Migration[8.1]
  def change
    create_trigger :logidze_on_feature_intent_issue_prerequisite_mappings, on: :feature_intent_issue_prerequisite_mappings
  end
end
