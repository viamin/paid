# frozen_string_literal: true

# @spec FACET-CONFIDENCE-021
class CreateFacetConfidenceEvaluationLabelRevisions < ActiveRecord::Migration[8.1]
  def change
    create_table :facet_confidence_evaluation_label_revisions,
      comment: "Append-only post-unblinding corrections to frozen facet-confidence reference judgments (#4662)." do |t|
      t.references :facet_confidence_evaluation_label, null: false, foreign_key: true,
        comment: "The immutable blinded reference judgment being corrected."
      t.string :verdict, null: false, comment: "Corrected verdict status."
      t.string :intent_band, null: false, comment: "Corrected intent assessment band."
      t.string :technical_band, null: false, comment: "Corrected technical assessment band."
      t.string :readiness, null: false, comment: "Corrected readiness derived from the corrected bands."
      t.text :cited_evidence_reference, null: false, comment: "Case evidence reference cited for the correction."
      t.text :reason, null: false, comment: "Judge's reason for the corrected judgment."
      t.text :revision_reason, null: false, comment: "Why the frozen blinded judgment was corrected after unblinding."
      t.references :revised_by, null: false, foreign_key: { to_table: :users },
        comment: "Authenticated sole reference judge who recorded this correction."
      t.datetime :revised_at, null: false, comment: "When the post-unblinding correction was recorded."
      t.timestamps
    end

    add_index :facet_confidence_evaluation_label_revisions,
      %i[facet_confidence_evaluation_label_id revised_at],
      name: "idx_facet_confidence_label_revisions_chronological"
  end
end
