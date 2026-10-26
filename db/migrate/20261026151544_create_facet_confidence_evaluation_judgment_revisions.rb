class CreateFacetConfidenceEvaluationJudgmentRevisions < ActiveRecord::Migration[8.1]
  def up
    create_table :facet_confidence_evaluation_judgment_revisions,
      comment: "Attributed post-unblinding corrections to frozen facet-confidence reference judgments." do |t|
      t.references :facet_confidence_evaluation_label, null: false,
        foreign_key: { on_delete: :cascade }, comment: "The immutable blinded judgment being corrected."
      t.string :verdict, null: false
      t.string :intent_band, null: false
      t.string :technical_band, null: false
      t.string :readiness, null: false
      t.text :cited_evidence_reference, null: false
      t.text :reason, null: false, comment: "Reason for this post-unblinding correction."
      t.references :revised_by, null: false, foreign_key: { to_table: :users },
        comment: "Authenticated sole reference judge who recorded the correction."
      t.datetime :revised_at, null: false
      t.timestamps
    end

    add_index :facet_confidence_evaluation_judgment_revisions,
      %i[facet_confidence_evaluation_label_id revised_at],
      name: "idx_facet_confidence_judgment_revisions_label_time"
    enable_rls
  end

  def down
    drop_table :facet_confidence_evaluation_judgment_revisions
  end

  private

  def enable_rls
    safety_assured do
      execute "ALTER TABLE facet_confidence_evaluation_judgment_revisions ENABLE ROW LEVEL SECURITY"
      execute "ALTER TABLE facet_confidence_evaluation_judgment_revisions FORCE ROW LEVEL SECURITY"
      execute <<~SQL
        CREATE POLICY tenant_isolation ON facet_confidence_evaluation_judgment_revisions
        AS PERMISSIVE
        FOR ALL
        USING (
          paid_tenant_bypass() OR EXISTS (
            SELECT 1
            FROM facet_confidence_evaluation_labels labels
            INNER JOIN facet_confidence_evaluations evaluations
              ON evaluations.id = labels.facet_confidence_evaluation_id
            INNER JOIN projects ON projects.id = evaluations.project_id
            WHERE labels.id = facet_confidence_evaluation_judgment_revisions.facet_confidence_evaluation_label_id
              AND projects.account_id = paid_current_account_id()
          )
        )
        WITH CHECK (
          paid_tenant_bypass() OR EXISTS (
            SELECT 1
            FROM facet_confidence_evaluation_labels labels
            INNER JOIN facet_confidence_evaluations evaluations
              ON evaluations.id = labels.facet_confidence_evaluation_id
            INNER JOIN projects ON projects.id = evaluations.project_id
            WHERE labels.id = facet_confidence_evaluation_judgment_revisions.facet_confidence_evaluation_label_id
              AND projects.account_id = paid_current_account_id()
          )
        )
      SQL
    end
  end
end
