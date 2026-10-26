# frozen_string_literal: true

# The Rails generator could not run in this environment because the supplied
# database role is deliberately rejected by Database::RuntimeRoleGuard. This
# migration is the generated-equivalent additive schema change for #4662.
# @spec FACET-CONFIDENCE-021
class AddRevisionsToFacetConfidenceEvaluationLabels < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def change
    add_column :facet_confidence_evaluation_labels, :revised_verdict, :string,
      comment: "Post-unblinding verdict correction; the original verdict remains immutable."
    add_column :facet_confidence_evaluation_labels, :revised_intent_band, :string,
      comment: "Post-unblinding intent-band correction."
    add_column :facet_confidence_evaluation_labels, :revised_technical_band, :string,
      comment: "Post-unblinding technical-band correction."
    add_column :facet_confidence_evaluation_labels, :revised_readiness, :string,
      comment: "Post-unblinding readiness correction."
    add_column :facet_confidence_evaluation_labels, :revised_cited_evidence_reference, :text,
      comment: "Case evidence reference cited by the correction."
    add_column :facet_confidence_evaluation_labels, :revised_reason, :text,
      comment: "Judge's required reason for the post-unblinding correction."
    add_reference :facet_confidence_evaluation_labels, :revised_by,
      index: { algorithm: :concurrently }, comment: "Authenticated judge who recorded the correction."
    add_column :facet_confidence_evaluation_labels, :revised_at, :datetime,
      comment: "When the post-unblinding correction was recorded."
  end
end
