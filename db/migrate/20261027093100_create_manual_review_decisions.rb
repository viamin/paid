# frozen_string_literal: true

# An operator's recorded verdict on a parked issue, bound to the exact
# revision of the issue's intent the verdict was made against (#4640).
#
# The binding is what makes the verdict meaningful: an issue's intent can
# change after the verdict, and a stale verdict must not silently authorize
# work against a revision nobody reviewed. One decision per revision keeps a
# repeated submit idempotent.
#
# @spec MANUAL-REVIEW-RECOVERY-002
class CreateManualReviewDecisions < ActiveRecord::Migration[8.1]
  def change
    create_table :manual_review_decisions do |t|
      t.references :issue, null: false, foreign_key: true
      t.references :project, null: false, foreign_key: true
      t.references :actor, null: false, foreign_key: { to_table: :users }
      t.string :cause, null: false
      t.string :decision, null: false
      t.text :reason, null: false
      t.string :revision_digest, null: false
      t.timestamps
    end

    add_index :manual_review_decisions, [ :issue_id, :revision_digest ],
      unique: true, name: "index_manual_review_decisions_on_issue_and_revision"
  end
end
