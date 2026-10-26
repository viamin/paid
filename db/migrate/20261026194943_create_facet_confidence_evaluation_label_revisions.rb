# frozen_string_literal: true

# @spec FACET-CONFIDENCE-021
class CreateFacetConfidenceEvaluationLabelRevisions < ActiveRecord::Migration[8.1]
  def change
    create_table :facet_confidence_evaluation_label_revisions,
      comment: "Post-unblinding corrections to frozen reference judgments; originals remain immutable." do |t|
      t.references :facet_confidence_evaluation_label, null: false, foreign_key: true
      t.string :verdict, null: false
      t.string :intent_band, null: false
      t.string :technical_band, null: false
      t.string :readiness, null: false
      t.text :cited_evidence_reference, null: false
      t.text :reason, null: false
      t.references :recorded_by, null: false, foreign_key: { to_table: :users }
      t.datetime :recorded_at, null: false
      t.timestamps
    end
  end
end
