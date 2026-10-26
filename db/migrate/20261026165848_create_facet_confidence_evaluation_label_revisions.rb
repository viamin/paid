# frozen_string_literal: true

# @spec FACET-CONFIDENCE-021
class CreateFacetConfidenceEvaluationLabelRevisions < ActiveRecord::Migration[8.1]
  def change
    create_table :facet_confidence_evaluation_label_revisions do |t|
      t.references :facet_confidence_evaluation, null: false, foreign_key: true
      t.references :facet_confidence_evaluation_label, null: false, foreign_key: true, index: false
      t.string :case_id, null: false
      t.string :verdict, null: false
      t.string :intent_band, null: false
      t.string :technical_band, null: false
      t.string :readiness, null: false
      t.text :cited_evidence_reference, null: false
      t.text :reason, null: false
      t.references :revised_by, null: false, foreign_key: { to_table: :users }
      t.datetime :revised_at, null: false
      t.timestamps
    end

    add_index :facet_confidence_evaluation_label_revisions,
      %i[facet_confidence_evaluation_label_id created_at],
      name: "idx_facet_confidence_label_revisions_label_created"
  end
end
