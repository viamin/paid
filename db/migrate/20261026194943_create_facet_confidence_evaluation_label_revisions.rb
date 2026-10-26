# frozen_string_literal: true

# @spec FACET-CONFIDENCE-021
class CreateFacetConfidenceEvaluationLabelRevisions < ActiveRecord::Migration[8.1]
  def up
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

    enable_rls
  end

  def down
    drop_table :facet_confidence_evaluation_label_revisions
  end

  private

  # A revision is tenant-scoped through its label, evaluation, and project.
  # Keep this same database backstop as the owning tables so application-level
  # authorization mistakes cannot cross account boundaries.
  def enable_rls
    safety_assured do
      execute "ALTER TABLE facet_confidence_evaluation_label_revisions ENABLE ROW LEVEL SECURITY"
      execute "ALTER TABLE facet_confidence_evaluation_label_revisions FORCE ROW LEVEL SECURITY"

      execute <<~SQL
        CREATE POLICY tenant_isolation ON facet_confidence_evaluation_label_revisions
        AS PERMISSIVE
        FOR ALL
        USING (
          paid_tenant_bypass() OR (
            EXISTS (
              SELECT 1 FROM facet_confidence_evaluation_labels labels
              INNER JOIN facet_confidence_evaluations evaluations
                ON evaluations.id = labels.facet_confidence_evaluation_id
              INNER JOIN projects ON projects.id = evaluations.project_id
              WHERE labels.id = facet_confidence_evaluation_label_revisions.facet_confidence_evaluation_label_id
                AND projects.account_id = paid_current_account_id()
            )
          )
        )
        WITH CHECK (
          paid_tenant_bypass() OR (
            EXISTS (
              SELECT 1 FROM facet_confidence_evaluation_labels labels
              INNER JOIN facet_confidence_evaluations evaluations
                ON evaluations.id = labels.facet_confidence_evaluation_id
              INNER JOIN projects ON projects.id = evaluations.project_id
              WHERE labels.id = facet_confidence_evaluation_label_revisions.facet_confidence_evaluation_label_id
                AND projects.account_id = paid_current_account_id()
            )
          )
        )
      SQL
    end
  end
end
