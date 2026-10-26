# frozen_string_literal: true

# @spec FACET-CONFIDENCE-021
class AddRevisionsToFacetConfidenceEvaluationLabels < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def change
    add_column :facet_confidence_evaluation_labels, :revised_verdict, :string,
      comment: "Post-unblinding corrected verdict; original verdict remains immutable."
    add_column :facet_confidence_evaluation_labels, :revised_intent_band, :string,
      comment: "Post-unblinding corrected intent band."
    add_column :facet_confidence_evaluation_labels, :revised_technical_band, :string,
      comment: "Post-unblinding corrected technical band."
    add_column :facet_confidence_evaluation_labels, :revised_readiness, :string,
      comment: "Post-unblinding corrected readiness."
    add_column :facet_confidence_evaluation_labels, :revised_cited_evidence_reference, :text,
      comment: "Evidence reference for the correction."
    add_column :facet_confidence_evaluation_labels, :revised_reason, :text,
      comment: "Required independent reason for the correction."
    add_reference :facet_confidence_evaluation_labels, :revised_by,
      index: { algorithm: :concurrently },
      comment: "Authenticated original judge who recorded the correction."
    add_column :facet_confidence_evaluation_labels, :revised_at, :datetime,
      comment: "When the post-unblinding correction was recorded."
  end
end
