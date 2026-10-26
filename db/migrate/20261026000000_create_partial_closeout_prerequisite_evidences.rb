# frozen_string_literal: true

# @spec PARTIAL-CLOSEOUT-030
class CreatePartialCloseoutPrerequisiteEvidences < ActiveRecord::Migration[8.1]
  def change
    add_reference :intent_conformance_shadow_evaluations, :originating_issue, foreign_key: { to_table: :issues }, comment: "Partial-closeout item that requested this evaluation, when applicable."

    create_table :partial_closeout_prerequisite_evidences,
      comment: "Criterion-scoped submitted prerequisite evidence and its bounded assessment." do |t|
      t.references :account, null: false, foreign_key: true
      t.references :issue, null: false, foreign_key: true
      t.references :actor, null: false, foreign_key: { to_table: :users }
      t.references :shadow_evaluation, foreign_key: { to_table: :intent_conformance_shadow_evaluations }
      t.string :criterion, null: false
      t.string :source_revision, null: false
      t.string :intent_revision, null: false
      t.string :evidence_type, null: false
      t.string :evidence_reference, null: false
      t.text :explanation, null: false
      t.string :outcome, null: false, default: "submitted"
      t.text :reasoning
      t.text :next_action
      t.string :idempotency_key, null: false
      t.datetime :assessed_at
      t.timestamps
    end

    add_index :partial_closeout_prerequisite_evidences, %i[issue_id criterion created_at], name: "idx_closeout_evidence_issue_criterion"
    add_index :partial_closeout_prerequisite_evidences, %i[account_id idempotency_key], unique: true, name: "idx_closeout_evidence_idempotency"
    add_check_constraint :partial_closeout_prerequisite_evidences,
      "outcome IN ('submitted', 'sufficient', 'insufficient', 'stale', 'unavailable')", name: "closeout_evidence_outcome"
  end
end
