# frozen_string_literal: true

# @spec FACET-CONFIDENCE-021
class AddRevisionsToFacetConfidenceEvaluationLabels < ActiveRecord::Migration[8.1]
  def change
    add_column :facet_confidence_evaluation_labels, :revised_verdict, :string,
      comment: "Post-unblinding verdict correction; the original verdict remains the frozen measurement input."
    add_column :facet_confidence_evaluation_labels, :revised_intent_band, :string,
      comment: "Post-unblinding intent-band correction; the original band remains the frozen measurement input."
    add_column :facet_confidence_evaluation_labels, :revised_technical_band, :string,
      comment: "Post-unblinding technical-band correction; the original band remains the frozen measurement input."
    add_column :facet_confidence_evaluation_labels, :revised_readiness, :string,
      comment: "Post-unblinding readiness correction; the original readiness remains the frozen measurement input."
    add_column :facet_confidence_evaluation_labels, :revised_cited_evidence_reference, :text,
      comment: "Case evidence reference cited by the post-unblinding correction."
    add_column :facet_confidence_evaluation_labels, :revised_reason, :text,
      comment: "Sole judge's required reason for the post-unblinding correction."
    add_column :facet_confidence_evaluation_labels, :revised_at, :datetime,
      comment: "When the post-unblinding correction was recorded."
  end
end
