# frozen_string_literal: true

# @spec INTENT-CONFORMANCE-ROLLOUT-005 @spec INTENT-CONFORMANCE-ROLLOUT-006
# @spec INTENT-CONFORMANCE-ROLLOUT-007 @spec INTENT-CONFORMANCE-ROLLOUT-008
class CreateIntentConformanceShadowEvaluations < ActiveRecord::Migration[8.1]
  def up
    create_table :intent_conformance_shadow_evaluations,
      comment: "Solo-maintainer RDR-067 shadow evaluation: one labeling session per evidence generation " \
        "(project, purpose, frozen corpus manifest digest) with blinded reference labels, executed reviewer " \
        "runs, and the reproducible report (#4594)." do |t|
      t.references :project, null: false, foreign_key: true,
        comment: "Project whose corpus is evaluated; also the authorization boundary."
      t.string :policy, null: false, default: "solo",
        comment: "Explicitly selected evaluation policy. Only 'solo' is UI-selectable; the team policy stays CLI/ledger-owned."
      t.string :status, null: false, default: "labeling",
        comment: "labeling → frozen → executing → completed | failed (see IntentConformanceShadowEvaluation::STATUSES)."
      t.string :purpose, null: false, default: "",
        comment: "Evaluation purpose key (e.g. 'rdr-067-measured-rollout') linking the originating Inbox item."
      t.string :manifest_path, null: false,
        comment: "Repository-relative path of the frozen corpus manifest."
      t.string :manifest_commit, null: false, default: "",
        comment: "Git commit SHA of the frozen corpus manifest."
      t.string :manifest_digest, null: false, default: "",
        comment: "SHA-256 of the frozen corpus manifest content; changing the corpus starts a new evidence generation."
      t.references :solo_maintainer, foreign_key: { to_table: :users },
        comment: "The single authenticated maintainer declared for a solo evaluation; only this user labels, revises, and freezes."
      t.references :created_by, null: false, foreign_key: { to_table: :users },
        comment: "Authenticated operator who started the evaluation."
      t.datetime :labels_frozen_at, comment: "Set by the explicit finish action; reviewer outputs stay hidden until then."
      t.datetime :execute_started_at, comment: "When reviewer execution last started."
      t.datetime :completed_at, comment: "When every case had an executed reviewer verdict."
      t.jsonb :report, null: false, default: {},
        comment: "Structured reproducible report (identities, labels, verdicts, confusion counts, provenance)."
      t.text :report_markdown, comment: "Rendered markdown of the reproducible report."
      t.text :last_failure_reason, comment: "Why execution ended (or partially ended) without evaluated verdicts for every case."
      t.timestamps
    end

    add_index :intent_conformance_shadow_evaluations, %i[project_id purpose manifest_digest],
      unique: true,
      name: "idx_shadow_evaluations_one_per_evidence_generation",
      comment: "Repeated Start/Resume actions reuse the same evaluation for the same evidence generation."

    create_table :intent_conformance_shadow_evaluation_labels,
      comment: "Durable blinded reference labels for one evaluation: save/resume state per case, original " \
        "outcome preserved, post-result revisions appended alongside (#4594)." do |t|
      t.references :shadow_evaluation, null: false, foreign_key: { to_table: :intent_conformance_shadow_evaluations },
        comment: "Owning evaluation."
      t.string :case_id, null: false, comment: "Case id inside the frozen corpus manifest."
      t.string :state, null: false, default: "pending",
        comment: "pending | labeled | skipped. Skipped cases are never counted as completed and block freeze."
      t.string :outcome, comment: "within_scope | material_drift | uncertain; set when labeled."
      t.text :cited_design_claim, comment: "Cited approved design claim for the label."
      t.text :reason, comment: "Maintainer's reason for the label."
      t.references :recorded_by, null: false, foreign_key: { to_table: :users },
        comment: "Authenticated maintainer who recorded the label."
      t.datetime :recorded_at, comment: "When the label (or last save) was recorded."
      t.string :revised_outcome, comment: "Appended post-result revision; never overwrites the original outcome."
      t.text :revised_reason, comment: "Reason for the post-result revision."
      t.references :revised_by, foreign_key: { to_table: :users },
        comment: "Authenticated maintainer who recorded the revision."
      t.datetime :revised_at, comment: "When the revision was recorded."
      t.timestamps
    end

    add_index :intent_conformance_shadow_evaluation_labels, %i[shadow_evaluation_id case_id],
      unique: true,
      name: "idx_shadow_evaluation_labels_case",
      comment: "One durable label row per case: saves update in place, giving durable save/resume."

    create_table :intent_conformance_shadow_evaluation_runs,
      comment: "Executed reviewer run per corpus case: the actual reviewer verdict recorded after the " \
        "reference set froze (#4594). Failures persist as not_evaluated with a reason." do |t|
      t.references :shadow_evaluation, null: false, foreign_key: { to_table: :intent_conformance_shadow_evaluations },
        comment: "Owning evaluation."
      t.string :case_id, null: false, comment: "Case id inside the frozen corpus manifest."
      t.string :reviewer_run_id, null: false, default: "",
        comment: "Identifier for the reviewer invocation that produced this verdict."
      t.string :reviewer_model, null: false, default: "", comment: "Model the reviewer ran with."
      t.string :prompt_digest, null: false, default: "", comment: "Digest of the reviewer prompt identity."
      t.string :verdict, null: false, default: "not_evaluated",
        comment: "within_scope | material_drift | uncertain | not_evaluated."
      t.integer :cost_cents, null: false, default: 0, comment: "Reviewer invocation cost when available."
      t.text :failure_reason, comment: "Why the reviewer output is missing or failed for this case."
      t.datetime :recorded_at, null: false, comment: "When the run was recorded."
      t.timestamps
    end

    add_index :intent_conformance_shadow_evaluation_runs, %i[shadow_evaluation_id case_id],
      unique: true,
      name: "idx_shadow_evaluation_runs_case",
      comment: "At most one executed reviewer run per case; re-execution retries failures in place."

    enable_rls
  end

  def down
    drop_table :intent_conformance_shadow_evaluation_runs
    drop_table :intent_conformance_shadow_evaluation_labels
    drop_table :intent_conformance_shadow_evaluations
  end

  private

  # RLS is the documented exception to the Rails-helper rule (AGENTS.md):
  # PostgreSQL row-level security and CREATE POLICY have no equivalent
  # helper, so the SQL stays minimal and isolated to this block. Tenancy is
  # keyed through the project (directly, or through the owning evaluation).
  def enable_rls
    safety_assured do
      execute "ALTER TABLE intent_conformance_shadow_evaluations ENABLE ROW LEVEL SECURITY"
      execute "ALTER TABLE intent_conformance_shadow_evaluations FORCE ROW LEVEL SECURITY"
      execute "ALTER TABLE intent_conformance_shadow_evaluation_labels ENABLE ROW LEVEL SECURITY"
      execute "ALTER TABLE intent_conformance_shadow_evaluation_labels FORCE ROW LEVEL SECURITY"
      execute "ALTER TABLE intent_conformance_shadow_evaluation_runs ENABLE ROW LEVEL SECURITY"
      execute "ALTER TABLE intent_conformance_shadow_evaluation_runs FORCE ROW LEVEL SECURITY"

      execute <<~SQL
        CREATE POLICY tenant_isolation ON intent_conformance_shadow_evaluations
        AS PERMISSIVE
        FOR ALL
        USING (
          paid_tenant_bypass() OR (
            EXISTS (
              SELECT 1 FROM projects
              WHERE projects.id = intent_conformance_shadow_evaluations.project_id
                AND projects.account_id = paid_current_account_id()
            )
          )
        )
        WITH CHECK (
          paid_tenant_bypass() OR (
            EXISTS (
              SELECT 1 FROM projects
              WHERE projects.id = intent_conformance_shadow_evaluations.project_id
                AND projects.account_id = paid_current_account_id()
            )
          )
        )
      SQL

      execute <<~SQL
        CREATE POLICY tenant_isolation ON intent_conformance_shadow_evaluation_labels
        AS PERMISSIVE
        FOR ALL
        USING (
          paid_tenant_bypass() OR (
            EXISTS (
              SELECT 1 FROM intent_conformance_shadow_evaluations e
              INNER JOIN projects ON projects.id = e.project_id
              WHERE e.id = intent_conformance_shadow_evaluation_labels.shadow_evaluation_id
                AND projects.account_id = paid_current_account_id()
            )
          )
        )
        WITH CHECK (
          paid_tenant_bypass() OR (
            EXISTS (
              SELECT 1 FROM intent_conformance_shadow_evaluations e
              INNER JOIN projects ON projects.id = e.project_id
              WHERE e.id = intent_conformance_shadow_evaluation_labels.shadow_evaluation_id
                AND projects.account_id = paid_current_account_id()
            )
          )
        )
      SQL

      execute <<~SQL
        CREATE POLICY tenant_isolation ON intent_conformance_shadow_evaluation_runs
        AS PERMISSIVE
        FOR ALL
        USING (
          paid_tenant_bypass() OR (
            EXISTS (
              SELECT 1 FROM intent_conformance_shadow_evaluations e
              INNER JOIN projects ON projects.id = e.project_id
              WHERE e.id = intent_conformance_shadow_evaluation_runs.shadow_evaluation_id
                AND projects.account_id = paid_current_account_id()
            )
          )
        )
        WITH CHECK (
          paid_tenant_bypass() OR (
            EXISTS (
              SELECT 1 FROM intent_conformance_shadow_evaluations e
              INNER JOIN projects ON projects.id = e.project_id
              WHERE e.id = intent_conformance_shadow_evaluation_runs.shadow_evaluation_id
                AND projects.account_id = paid_current_account_id()
            )
          )
        )
      SQL
    end
  end
end
