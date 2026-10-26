# frozen_string_literal: true

# @spec FACET-CONFIDENCE-020 @spec FACET-CONFIDENCE-021
class CreateFacetConfidenceEvaluations < ActiveRecord::Migration[8.1]
  def up
    create_table :facet_confidence_evaluations,
      comment: "Facet-confidence closeout evaluation (#4596): one blinded reference-judgment session per " \
        "originating closeout (issue, frozen corpus digest) over the shipped RDR-070 corpus." do |t|
      t.references :project, null: false, foreign_key: true,
        comment: "Project whose closeout is evaluated; also the authorization boundary."
      t.references :issue, null: false, foreign_key: true,
        comment: "Originating partial-closeout work item; links the evaluation and its report back to the Inbox item."
      t.string :status, null: false, default: "labeling",
        comment: "labeling | frozen (see FacetConfidenceEvaluation::STATUSES)."
      t.string :corpus_path, null: false,
        comment: "Repository-relative path of the frozen corpus manifest."
      t.string :corpus_digest, null: false,
        comment: "SHA-256 of the frozen corpus manifest content; changing the corpus starts a new evidence generation."
      t.string :corpus_version, null: false, comment: "Frozen corpus version pinned at start."
      t.string :rubric_version, null: false, comment: "Rubric version pinned at start."
      t.string :model_version, null: false, comment: "Model version pinned at start."
      t.string :source_revision, comment: "Closeout source revision recorded at start."
      t.datetime :labels_frozen_at,
        comment: "Set by the explicit freeze action; frozen expectations stay hidden until then."
      t.jsonb :report, null: false, default: {},
        comment: "Compiled reproducible report (identities, judgments, measures, provenance)."
      t.text :report_markdown, comment: "Rendered markdown of the reproducible report."
      t.references :created_by, null: false, foreign_key: { to_table: :users },
        comment: "Authenticated operator who started the evaluation and is its sole reference judge."
      t.timestamps
    end

    add_index :facet_confidence_evaluations, %i[issue_id corpus_digest], unique: true,
      name: "idx_facet_confidence_evaluations_one_per_closeout_generation",
      comment: "Repeated Start/Resume actions reuse the same evaluation for the same evidence generation."

    create_table :facet_confidence_evaluation_labels,
      comment: "Durable blinded reference judgment for one corpus case of a facet-confidence closeout " \
        "evaluation: save/resume state per case (#4596)." do |t|
      t.references :facet_confidence_evaluation, null: false,
        foreign_key: { to_table: :facet_confidence_evaluations }, comment: "Owning evaluation."
      t.string :case_id, null: false, comment: "Case id inside the frozen corpus manifest."
      t.string :state, null: false, default: "pending",
        comment: "pending | labeled | skipped. Skipped cases are never counted as completed and block freeze."
      t.string :verdict, comment: "completed | clarification_needed | unknown; set when labeled."
      t.string :intent_band, comment: "unknown | below_threshold | at_or_above_threshold; set when labeled."
      t.string :technical_band, comment: "unknown | below_threshold | at_or_above_threshold; set when labeled."
      t.string :readiness, comment: "ready | not_ready; must follow the judged bands; set when labeled."
      t.text :cited_evidence_reference, comment: "One evidence reference from the case cited by the judge."
      t.text :reason, comment: "Judge's reason for the judgment."
      t.references :recorded_by, null: false, foreign_key: { to_table: :users },
        comment: "Authenticated operator who recorded the judgment."
      t.datetime :recorded_at, null: false, comment: "When the judgment (or last save) was recorded."
      t.timestamps
    end

    add_index :facet_confidence_evaluation_labels, %i[facet_confidence_evaluation_id case_id],
      unique: true, name: "idx_facet_confidence_evaluation_labels_case",
      comment: "One durable judgment row per case: saves update in place, giving durable save/resume."

    enable_rls
  end

  def down
    drop_table :facet_confidence_evaluation_labels
    drop_table :facet_confidence_evaluations
  end

  private

  # RLS is the documented exception to the Rails-helper rule (AGENTS.md):
  # PostgreSQL row-level security and CREATE POLICY have no equivalent
  # helper, so the SQL stays minimal and isolated to this block. Tenancy is
  # keyed through the project (directly, or through the owning evaluation).
  def enable_rls
    safety_assured do
      execute "ALTER TABLE facet_confidence_evaluations ENABLE ROW LEVEL SECURITY"
      execute "ALTER TABLE facet_confidence_evaluations FORCE ROW LEVEL SECURITY"
      execute "ALTER TABLE facet_confidence_evaluation_labels ENABLE ROW LEVEL SECURITY"
      execute "ALTER TABLE facet_confidence_evaluation_labels FORCE ROW LEVEL SECURITY"

      execute <<~SQL
        CREATE POLICY tenant_isolation ON facet_confidence_evaluations
        AS PERMISSIVE
        FOR ALL
        USING (
          paid_tenant_bypass() OR (
            EXISTS (
              SELECT 1 FROM projects
              WHERE projects.id = facet_confidence_evaluations.project_id
                AND projects.account_id = paid_current_account_id()
            )
          )
        )
        WITH CHECK (
          paid_tenant_bypass() OR (
            EXISTS (
              SELECT 1 FROM projects
              WHERE projects.id = facet_confidence_evaluations.project_id
                AND projects.account_id = paid_current_account_id()
            )
          )
        )
      SQL

      execute <<~SQL
        CREATE POLICY tenant_isolation ON facet_confidence_evaluation_labels
        AS PERMISSIVE
        FOR ALL
        USING (
          paid_tenant_bypass() OR (
            EXISTS (
              SELECT 1 FROM facet_confidence_evaluations e
              INNER JOIN projects ON projects.id = e.project_id
              WHERE e.id = facet_confidence_evaluation_labels.facet_confidence_evaluation_id
                AND projects.account_id = paid_current_account_id()
            )
          )
        )
        WITH CHECK (
          paid_tenant_bypass() OR (
            EXISTS (
              SELECT 1 FROM facet_confidence_evaluations e
              INNER JOIN projects ON projects.id = e.project_id
              WHERE e.id = facet_confidence_evaluation_labels.facet_confidence_evaluation_id
                AND projects.account_id = paid_current_account_id()
            )
          )
        )
      SQL
    end
  end
end
