# frozen_string_literal: true

class EnforceTaskKindOnFeatureIntentIssuePublications < ActiveRecord::Migration[8.1] # @spec CONFIDENCE-DELIVERY-017
  TASK_KIND_PRESENT_CONSTRAINT = "feature_intent_issue_publications_task_kind_present"

  disable_ddl_transaction!

  def up
    unless check_constraint_exists?(:feature_intent_issue_publications, name: TASK_KIND_PRESENT_CONSTRAINT)
      add_check_constraint :feature_intent_issue_publications, "task_kind IS NOT NULL",
        name: TASK_KIND_PRESENT_CONSTRAINT, validate: false
    end
    validate_check_constraint :feature_intent_issue_publications, name: TASK_KIND_PRESENT_CONSTRAINT
    change_column_null :feature_intent_issue_publications, :task_kind, false
    remove_check_constraint :feature_intent_issue_publications, name: TASK_KIND_PRESENT_CONSTRAINT
  end

  def down
    change_column_null :feature_intent_issue_publications, :task_kind, true
  end
end
