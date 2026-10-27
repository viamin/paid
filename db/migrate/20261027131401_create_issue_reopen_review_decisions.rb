# frozen_string_literal: true

# Records an operator's intent-validation decision for an issue that was
# reopened after closure. The decision is bound to the issue's evidence
# revision, so a later change to the issue invalidates it.
#
# @spec MANUAL-REVIEW-RECOVERY-002
class CreateIssueReopenReviewDecisions < ActiveRecord::Migration[8.1]
  def change
    create_table :issue_reopen_review_decisions do |t|
      t.references :issue, null: false, foreign_key: true
      t.references :project, null: false, foreign_key: true
      t.references :decided_by, null: false, foreign_key: { to_table: :users }
      t.string :decision, null: false, comment: "intent_valid (the original intent still holds) or intent_superseded."
      t.text :reason, null: false, comment: "Required operator justification for the decision."
      t.text :remaining_scope, comment: "The scope the operator still expects to be delivered."
      t.string :evidence_revision, null: false, comment: "Digest of the issue content the decision was bound to."
      t.timestamps
    end

    add_index :issue_reopen_review_decisions, [ :issue_id, :created_at ],
      name: "index_issue_reopen_review_decisions_on_issue_and_created_at"
    add_index :issue_reopen_review_decisions, :evidence_revision
  end
end
