# frozen_string_literal: true

# @spec FACET-CONFIDENCE-021
class AddRevisionsToFacetConfidenceEvaluationLabels < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def change
    add_column :facet_confidence_evaluation_labels, :revised_verdict, :string,
      comment: "Post-unblinding corrected verdict; the original blinded verdict remains unchanged."
    add_column :facet_confidence_evaluation_labels, :revised_intent_band, :string,
      comment: "Post-unblinding corrected intent band."
    add_column :facet_confidence_evaluation_labels, :revised_technical_band, :string,
      comment: "Post-unblinding corrected technical band."
    add_column :facet_confidence_evaluation_labels, :revised_readiness, :string,
      comment: "Post-unblinding corrected readiness derived from corrected bands."
    add_column :facet_confidence_evaluation_labels, :revised_cited_evidence_reference, :text,
      comment: "Case-evidence reference supporting the correction."
    add_column :facet_confidence_evaluation_labels, :revised_reason, :text,
      comment: "Required reason for the post-unblinding correction."
    add_reference :facet_confidence_evaluation_labels, :revised_by,
      index: { algorithm: :concurrently }, comment: "Authenticated sole judge who appended the correction."
    add_column :facet_confidence_evaluation_labels, :revised_at, :datetime,
      comment: "When the immutable post-unblinding correction was appended."
  end
end
