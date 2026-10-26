class AddPostUnblindingRevisionsToFacetConfidenceEvaluationLabels < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def change
    add_column :facet_confidence_evaluation_labels, :revised_verdict, :string, comment: "Post-unblinding verdict correction; never overwrites the frozen judgment."
    add_column :facet_confidence_evaluation_labels, :revised_intent_band, :string, comment: "Post-unblinding intent-band correction."
    add_column :facet_confidence_evaluation_labels, :revised_technical_band, :string, comment: "Post-unblinding technical-band correction."
    add_column :facet_confidence_evaluation_labels, :revised_readiness, :string, comment: "Post-unblinding readiness correction; must follow revised bands."
    add_column :facet_confidence_evaluation_labels, :revised_cited_evidence_reference, :text, comment: "Corpus evidence reference cited by the post-unblinding correction."
    add_column :facet_confidence_evaluation_labels, :revised_reason, :text, comment: "Required reason for the post-unblinding correction."
    add_reference :facet_confidence_evaluation_labels, :revised_by, comment: "Authenticated sole judge who appended the correction.", index: { algorithm: :concurrently }
    add_column :facet_confidence_evaluation_labels, :revised_at, :datetime, comment: "When the post-unblinding correction was appended."
  end
end
