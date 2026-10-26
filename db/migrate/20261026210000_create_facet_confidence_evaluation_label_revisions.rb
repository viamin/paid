# frozen_string_literal: true

# @spec FACET-CONFIDENCE-022
class CreateFacetConfidenceEvaluationLabelRevisions < ActiveRecord::Migration[8.1]
  def up
    create_table :facet_confidence_evaluation_label_revisions,
      comment: "Append-only post-unblinding corrections to frozen facet-confidence reference labels (#4662)." do |t|
      t.references :facet_confidence_evaluation, null: false, foreign_key: true,
        comment: "Owning frozen evaluation and tenancy boundary."
      t.references :facet_confidence_evaluation_label, null: false, foreign_key: true,
        comment: "Original blinded label that remains unchanged."
      t.string :verdict, null: false, comment: "Corrected verdict status."
      t.string :intent_band, null: false, comment: "Corrected policy intent band."
      t.string :technical_band, null: false, comment: "Corrected policy technical band."
      t.string :readiness, null: false, comment: "Corrected readiness derived from the corrected bands."
      t.text :cited_evidence_reference, null: false, comment: "One citation from the frozen case evidence."
      t.text :reason, null: false, comment: "Required reason for the post-unblinding correction."
      t.references :recorded_by, null: false, foreign_key: { to_table: :users },
        comment: "Authenticated sole judge who recorded the correction."
      t.datetime :recorded_at, null: false, comment: "When this append-only correction was recorded."
      t.timestamps
    end

    add_index :facet_confidence_evaluation_label_revisions,
      %i[facet_confidence_evaluation_label_id recorded_at],
      name: "idx_facet_confidence_label_revisions_history"
    enable_rls
  end

  def down
    drop_table :facet_confidence_evaluation_label_revisions
  end

  private

  def enable_rls
    safety_assured do
      execute "ALTER TABLE facet_confidence_evaluation_label_revisions ENABLE ROW LEVEL SECURITY"
      execute "ALTER TABLE facet_confidence_evaluation_label_revisions FORCE ROW LEVEL SECURITY"
      execute <<~SQL
        CREATE POLICY tenant_isolation ON facet_confidence_evaluation_label_revisions
        AS PERMISSIVE
        FOR ALL
        USING (
          paid_tenant_bypass() OR EXISTS (
            SELECT 1 FROM facet_confidence_evaluations e
            INNER JOIN projects ON projects.id = e.project_id
            WHERE e.id = facet_confidence_evaluation_label_revisions.facet_confidence_evaluation_id
              AND projects.account_id = paid_current_account_id()
          )
        )
        WITH CHECK (
          paid_tenant_bypass() OR EXISTS (
            SELECT 1 FROM facet_confidence_evaluations e
            INNER JOIN projects ON projects.id = e.project_id
            WHERE e.id = facet_confidence_evaluation_label_revisions.facet_confidence_evaluation_id
              AND projects.account_id = paid_current_account_id()
          )
        )
      SQL
    end
  end
end
