# frozen_string_literal: true

class AddTaskKindToFeatureIntentIssuePublications < ActiveRecord::Migration[8.1] # @spec CONFIDENCE-DELIVERY-017
  TASK_KIND_PRESENT_CONSTRAINT = "feature_intent_issue_publications_task_kind_present"

  class PublicationReceipt < ActiveRecord::Base
    self.table_name = "feature_intent_issue_publications"
  end

  def up
    add_column :feature_intent_issue_publications, :task_kind, :string, limit: 16,
      comment: "Immutable admission semantics for the marker-identified task."
    PublicationReceipt.where(task_kind: nil).update_all(task_kind: "implementation")
    add_check_constraint :feature_intent_issue_publications, "task_kind IS NOT NULL",
      name: TASK_KIND_PRESENT_CONSTRAINT, validate: false
  end

  def down
    remove_check_constraint :feature_intent_issue_publications, name: TASK_KIND_PRESENT_CONSTRAINT, if_exists: true
    remove_column :feature_intent_issue_publications, :task_kind
  end
end
