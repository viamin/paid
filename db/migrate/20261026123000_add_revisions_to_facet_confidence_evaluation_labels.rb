# frozen_string_literal: true

# @spec FACET-CONFIDENCE-021
class AddRevisionsToFacetConfidenceEvaluationLabels < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def change
    add_column :facet_confidence_evaluation_labels, :revised_verdict, :string,
      comment: "Post-unblinding verdict revision; never overwrites the blinded judgment."
    add_column :facet_confidence_evaluation_labels, :revised_intent_band, :string,
      comment: "Post-unblinding intent-band revision."
    add_column :facet_confidence_evaluation_labels, :revised_technical_band, :string,
      comment: "Post-unblinding technical-band revision."
    add_column :facet_confidence_evaluation_labels, :revised_readiness, :string,
      comment: "Post-unblinding readiness revision."
    add_column :facet_confidence_evaluation_labels, :revised_cited_evidence_reference, :text,
      comment: "Evidence cited by the post-unblinding revision."
    add_column :facet_confidence_evaluation_labels, :revised_reason, :text,
      comment: "Required reason for the post-unblinding revision."
    add_reference :facet_confidence_evaluation_labels, :revised_by,
      index: { algorithm: :concurrently }, comment: "Authenticated judge who recorded the revision."
    add_column :facet_confidence_evaluation_labels, :revised_at, :datetime,
      comment: "When the post-unblinding revision was recorded."
  end
end
