# frozen_string_literal: true

class CreateTriggerLogidzeOnFeatureIntentIssuePrerequisites < ActiveRecord::Migration[8.1]
  def change
    create_trigger :logidze_on_feature_intent_issue_prerequisites, on: :feature_intent_issue_prerequisites
  end
end
