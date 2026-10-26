# frozen_string_literal: true

# @spec FACET-CONFIDENCE-021
class AddRevisionsToFacetConfidenceEvaluationLabels < ActiveRecord::Migration[8.1]
  def change
    change_table :facet_confidence_evaluation_labels, bulk: true do |t|
      t.string :revised_verdict, comment: "Post-unblinding corrected verdict; original verdict remains immutable."
      t.string :revised_intent_band, comment: "Post-unblinding corrected intent band."
      t.string :revised_technical_band, comment: "Post-unblinding corrected technical band."
      t.string :revised_readiness, comment: "Post-unblinding corrected readiness derived from corrected bands."
      t.text :revised_cited_evidence_reference, comment: "Case evidence reference cited by the correction."
      t.text :revised_reason, comment: "Reason for the post-unblinding correction."
      t.references :revised_by, foreign_key: { to_table: :users }, comment: "Authenticated sole judge who appended the correction."
      t.datetime :revised_at, comment: "When the post-unblinding correction was appended."
    end
  end
end
