# frozen_string_literal: true

# @spec INTENT-AMENDMENT-001 @spec INTENT-AMENDMENT-002
class CreateIntentConformanceResolutions < ActiveRecord::Migration[8.1]
  def change
    create_table :intent_conformance_resolutions, comment: "RDR-067 human resolution of an intent-conformance decision, bound to actor and PR head." do |t|
      t.references :project, null: false, foreign_key: true
      t.references :issue, null: false, foreign_key: true, comment: "Local pull-request issue the resolution targets."
      t.references :design_amendment, foreign_key: true, comment: "Amendment created when the resolution changes the product contract."
      t.references :resolved_by, null: false, foreign_key: { to_table: :users }
      t.string :resolution_type, null: false, comment: "Human choice: require_within_scope, implementation_exception, or design_amendment."
      t.integer :pull_request_number
      t.string :pr_head_sha, null: false, comment: "Exact PR head the resolution is bound to; a new head must be reviewed again."
      t.text :reason, null: false, comment: "Human's recorded reason for the resolution."
      t.boolean :changes_behavior, null: false, default: false, comment: "Approved product behavior changes; only valid on design_amendment resolutions."
      t.boolean :changes_constraints, null: false, default: false, comment: "Approved constraints change; only valid on design_amendment resolutions."
      t.boolean :changes_scope, null: false, default: false, comment: "Approved in/out scope changes; only valid on design_amendment resolutions."
      t.boolean :changes_acceptance_criteria, null: false, default: false, comment: "Approved acceptance criteria change; only valid on design_amendment resolutions."
      t.timestamps
    end

    add_index :intent_conformance_resolutions, %i[issue_id pr_head_sha], unique: true, name: "index_intent_resolutions_unique_issue_head"
    add_index :intent_conformance_resolutions, :resolution_type
  end
end
