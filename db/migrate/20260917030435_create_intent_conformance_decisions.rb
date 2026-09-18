# frozen_string_literal: true

# See RDR-067 (docs/rdrs/RDR-067-approved-intent-conformance.md).
class CreateIntentConformanceDecisions < ActiveRecord::Migration[8.1]
  def change
    create_table :intent_conformance_decisions,
      comment: "Human resolutions of a material_drift/uncertain/not_evaluated intent-conformance " \
        "verdict (RDR-067). A bounded_exception decision is scoped to its exact head_sha and stops " \
        "applying the moment a new commit changes the PR HEAD." do |t|
      t.references :issue, null: false, foreign_key: true, comment: "The pull request (Issue row) this decision resolves."
      t.references :verdict, null: true, foreign_key: { to_table: :intent_conformance_verdicts },
        comment: "The intent-conformance verdict this decision responds to, when one exists."
      t.references :actor, null: false, foreign_key: { to_table: :users }, comment: "The human who recorded this decision."
      t.string :action, null: false,
        comment: "fix_pr, bounded_exception, or design_amendment (see IntentConformanceDecision::ACTIONS)."
      t.string :head_sha, null: false, limit: 40,
        comment: "PR HEAD commit SHA this decision applies to. A bounded_exception only clears the " \
          "auto-merge blocker while the PR HEAD still matches this value."
      t.text :reason, null: false, comment: "Actor-supplied justification, shown in the Inbox and audit trail."

      t.timestamps
    end

    add_index :intent_conformance_decisions, [ :issue_id, :action, :head_sha ],
      name: "index_intent_conformance_decisions_on_issue_action_head"
  end
end
