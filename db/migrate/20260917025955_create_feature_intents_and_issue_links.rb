# frozen_string_literal: true

# @spec INTENT-AMENDMENT-003
class CreateFeatureIntentsAndIssueLinks < ActiveRecord::Migration[8.1]
  def change
    create_table :feature_intents, comment: "RDR-066 feature intent: links a feature's approved design revision to its issue tree." do |t|
      t.references :project, null: false, foreign_key: true, index: true
      t.string :title, null: false, comment: "Human-readable feature name."
      t.text :brief, comment: "Feature brief the design was researched from."
      t.string :status, null: false, default: "design_open", comment: "Lifecycle status: discovering, design_open, needs_decision, ready_for_approval, approved_waiting_for_merge, released, revising, cancelled."
      t.string :approved_design_revision, comment: "Merged repository revision of the currently approved design."
      t.datetime :approved_revision_recorded_at, comment: "When the approved design revision was recorded."
      t.timestamps
    end

    add_index :feature_intents, :status
    add_index :feature_intents, %i[project_id status]

    create_table :feature_intent_issues, comment: "Links feature intent records to their issue trees (implementation issues and PR issues)." do |t|
      t.references :feature_intent, null: false, foreign_key: true, index: true
      t.references :issue, null: false, foreign_key: true, index: { unique: true }
      t.timestamps
    end
  end
end
