# frozen_string_literal: true

# @spec FACET-CONFIDENCE-021
class AddRevisionsToFacetConfidenceEvaluationLabels < ActiveRecord::Migration[8.1]
  def change
    add_column :facet_confidence_evaluation_labels, :revised_verdict, :string,
      comment: "Post-unblinding corrected verdict; original blinded verdict remains immutable."
    add_column :facet_confidence_evaluation_labels, :revised_intent_band, :string,
      comment: "Post-unblinding corrected intent band; original blinded band remains immutable."
    add_column :facet_confidence_evaluation_labels, :revised_technical_band, :string,
      comment: "Post-unblinding corrected technical band; original blinded band remains immutable."
    add_column :facet_confidence_evaluation_labels, :revised_readiness, :string,
      comment: "Post-unblinding corrected readiness; must follow corrected bands."
    add_column :facet_confidence_evaluation_labels, :revised_cited_evidence_reference, :text,
      comment: "Case evidence reference supporting the corrected judgment."
    add_column :facet_confidence_evaluation_labels, :revised_reason, :text,
      comment: "Judge's required reason for the post-unblinding correction."
    add_reference :facet_confidence_evaluation_labels, :revised_by, foreign_key: { to_table: :users },
      comment: "Authenticated sole reference judge who recorded the correction."
    add_column :facet_confidence_evaluation_labels, :revised_at, :datetime,
      comment: "When the post-unblinding correction was recorded."
  end
end
