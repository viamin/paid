# frozen_string_literal: true

# @spec INTENT-CONFORMANCE-REVIEW-002 @spec INTENT-CONFORMANCE-REVIEW-003
class AddReviewerEvidenceToIntentConformanceVerdicts < ActiveRecord::Migration[8.1]
  def change
    return if column_exists?(:intent_conformance_verdicts, :reviewer_run_id)

    add_column :intent_conformance_verdicts, :reviewer_run_id, :string, null: false, default: "",
      comment: "Identifier for the independent reviewer invocation that produced this verdict, for audit correlation."
    add_column :intent_conformance_verdicts, :reviewer_model, :string, null: false, default: "",
      comment: "Model used by the independent reviewer run."
    add_column :intent_conformance_verdicts, :cited_design_claims, :jsonb, null: false, default: [],
      comment: "Approved design claims the reviewer cited as relevant to this outcome."
    add_column :intent_conformance_verdicts, :cited_diff_locations, :jsonb, null: false, default: [],
      comment: "PR diff locations (file plus note) the reviewer cited as relevant to this outcome."
    add_column :intent_conformance_verdicts, :reasoning_summary, :text,
      comment: "Reviewer's free-text explanation of the outcome, for human review."
  end
end
