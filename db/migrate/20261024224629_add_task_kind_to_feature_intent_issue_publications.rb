# frozen_string_literal: true

class AddTaskKindToFeatureIntentIssuePublications < ActiveRecord::Migration[8.1]
  def change
    add_column :feature_intent_issue_publications, :task_kind, :string, limit: 16, null: false,
      comment: "Immutable admission semantics for the marker-identified task."
  end
end
