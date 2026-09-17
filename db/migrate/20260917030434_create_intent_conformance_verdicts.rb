# frozen_string_literal: true

# See RDR-067 (docs/rdrs/RDR-067-approved-intent-conformance.md).
class CreateIntentConformanceVerdicts < ActiveRecord::Migration[8.1]
  def change
    create_table :intent_conformance_verdicts,
      comment: "Independent conformance verdicts comparing a feature PR's HEAD against its approved " \
        "design revision (RDR-067). One row per review run; the latest row for a given PR HEAD is " \
        "authoritative for auto-merge gating." do |t|
      t.references :issue, null: false, foreign_key: true, comment: "The pull request (Issue row) this verdict evaluates."
      t.references :reviewer_run, null: true, foreign_key: { to_table: :agent_runs },
        comment: "The independent reviewer AgentRun that produced this verdict, when available."
      t.string :pr_head_sha, null: false, limit: 40, comment: "PR HEAD commit SHA this verdict was evaluated against."
      t.string :approved_design_revision, null: false,
        comment: "Merged repository commit SHA of the approved RDR/LID design revision compared against."
      t.string :outcome, null: false,
        comment: "within_scope, material_drift, uncertain, or not_evaluated (see IntentConformanceVerdict::OUTCOMES)."
      t.string :reviewer_model, comment: "Model identifier used by the independent reviewer run, for audit."
      t.jsonb :cited_claims, null: false, default: [],
        comment: "Approved design claims the reviewer cited, e.g. [{design_ref:, claim_text:}]."
      t.jsonb :cited_diff_locations, null: false, default: [],
        comment: "PR diff locations the reviewer cited, e.g. [{file:, anchor:}]."
      t.text :reasoning_summary, comment: "Reviewer's reasoning summary, shown to a human resolving the Inbox decision."
      t.datetime :evaluated_at, null: false, comment: "When the reviewer run produced this verdict."

      t.timestamps
    end

    add_index :intent_conformance_verdicts, [ :issue_id, :pr_head_sha, :evaluated_at ],
      name: "index_intent_conformance_verdicts_on_issue_head_evaluated_at"
  end
end
