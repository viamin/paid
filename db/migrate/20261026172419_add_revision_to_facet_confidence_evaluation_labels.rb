class AddRevisionToFacetConfidenceEvaluationLabels < ActiveRecord::Migration[8.1]
  def change
    add_column :facet_confidence_evaluation_labels, :revised_verdict, :string
    add_column :facet_confidence_evaluation_labels, :revised_intent_band, :string
    add_column :facet_confidence_evaluation_labels, :revised_technical_band, :string
    add_column :facet_confidence_evaluation_labels, :revised_readiness, :string
    add_column :facet_confidence_evaluation_labels, :revised_cited_evidence_reference, :text
    add_column :facet_confidence_evaluation_labels, :revised_reason, :text
    add_reference :facet_confidence_evaluation_labels, :revised_by, index: false
    add_column :facet_confidence_evaluation_labels, :revised_at, :datetime
  end
end
