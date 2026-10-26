# frozen_string_literal: true

# @spec FACET-CONFIDENCE-022
class AddRevisionsToFacetConfidenceEvaluationLabels < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def change
    add_column :facet_confidence_evaluation_labels, :revised_verdict, :string,
      comment: "Post-unblinding verdict correction; never replaces the blinded verdict."
    add_column :facet_confidence_evaluation_labels, :revised_intent_band, :string,
      comment: "Post-unblinding intent-band correction."
    add_column :facet_confidence_evaluation_labels, :revised_technical_band, :string,
      comment: "Post-unblinding technical-band correction."
    add_column :facet_confidence_evaluation_labels, :revised_readiness, :string,
      comment: "Post-unblinding readiness correction."
    add_column :facet_confidence_evaluation_labels, :revised_cited_evidence_reference, :text,
      comment: "Evidence reference cited by the correction."
    add_column :facet_confidence_evaluation_labels, :revised_reason, :text,
      comment: "Reason for the post-unblinding correction."
    add_reference :facet_confidence_evaluation_labels, :revised_by,
      index: { algorithm: :concurrently }, comment: "Authenticated sole judge who recorded the correction."
    add_column :facet_confidence_evaluation_labels, :revised_at, :datetime,
      comment: "When the correction was recorded."
  end
end
