# frozen_string_literal: true

# Databases migrated through main already carry the earlier #3890 shape of
# intent_conformance_verdicts (recorded_at, cited_design_claims, string
# reviewer_run_id, project-keyed RLS). The approved RDR-067 design this branch
# ships stores reviewer identity as an agent_runs foreign key and evidence
# under different column names, so the two shapes cannot be converted row by
# row: the table is days old and its rows are regenerable reviewer output, so
# it is dropped and recreated in the approved shape instead.
#
# @spec INTENT-MERGE-GUARD-002 @spec INTENT-MERGE-GUARD-003 @spec INTENT-MERGE-GUARD-004
# @spec INTENT-CONFORMANCE-008
class AlignIntentConformanceVerdictsWithApprovedDesign < ActiveRecord::Migration[8.1]
  def up
    return unless table_exists?(:intent_conformance_verdicts)
    # Fresh databases create the approved-design shape directly in
    # CreateIntentConformanceVerdicts; nothing to align.
    return if column_exists?(:intent_conformance_verdicts, :evaluated_at)

    safety_assured do
      # CASCADE also drops intent_conformance_decisions' verdict_id foreign
      # key, which restore_decisions_verdict_foreign_key re-adds below.
      drop_table :intent_conformance_verdicts, force: :cascade
    end

    create_approved_design_verdicts
    restore_decisions_verdict_foreign_key
    enable_rls_on_intent_conformance_verdicts
  end

  def down
    return unless table_exists?(:intent_conformance_verdicts)
    return unless column_exists?(:intent_conformance_verdicts, :evaluated_at)

    safety_assured do
      drop_table :intent_conformance_verdicts, force: :cascade
    end

    create_legacy_verdicts
    restore_decisions_verdict_foreign_key
    enable_rls_on_legacy_verdicts
  end

  private

  def create_approved_design_verdicts
    create_table :intent_conformance_verdicts,
      comment: "Independent conformance verdicts comparing a feature PR's HEAD against its approved " \
        "design revision (RDR-067). One row per review run; the latest row for a given PR HEAD is " \
        "authoritative for auto-merge gating." do |t|
      t.references :project, null: false, foreign_key: true, comment: "The project the evaluated pull request belongs to."
      t.references :issue, null: false, foreign_key: true, comment: "The pull request (Issue row) this verdict evaluates."
      t.references :reviewer_run, null: true, foreign_key: { to_table: :agent_runs },
        comment: "The independent reviewer AgentRun that produced this verdict, when available."
      t.string :pr_head_sha, null: false, limit: 40, comment: "PR HEAD commit SHA this verdict was evaluated against."
      t.string :approved_design_revision, null: false,
        comment: "Merged repository commit SHA of the approved RDR/LID design revision compared against."
      t.string :outcome, null: false,
        comment: "within_scope, material_drift, uncertain, or not_evaluated (see IntentConformanceVerdict::OUTCOMES)."
      t.string :reviewer_model, comment: "Model identifier used by the independent reviewer run, for audit."
      t.jsonb :cited_claims, null: false, default: [],
        comment: "Approved design claims the reviewer cited, e.g. [{design_ref:, claim_text:}]."
      t.jsonb :cited_diff_locations, null: false, default: [],
        comment: "PR diff locations the reviewer cited, e.g. [{file:, anchor:}]."
      t.text :reasoning_summary, comment: "Reviewer's reasoning summary, shown to a human resolving the Inbox decision."
      t.datetime :evaluated_at, null: false, comment: "When the reviewer run produced this verdict."

      t.timestamps
    end

    add_index :intent_conformance_verdicts, [ :issue_id, :pr_head_sha, :evaluated_at ],
      name: "index_intent_conformance_verdicts_on_issue_head_evaluated_at"
    add_index :intent_conformance_verdicts, :outcome
  end

  # Mirrors main's CreateIntentConformanceVerdicts (#3890) plus its
  # AddReviewerEvidenceToIntentConformanceVerdicts follow-up.
  def create_legacy_verdicts
    create_table :intent_conformance_verdicts,
      comment: "RDR-067 intent-conformance verdict identity: outcome bound to an exact PR head and approved design revision." do |t|
      t.references :project, null: false, foreign_key: true
      t.references :issue, null: false, foreign_key: true, comment: "Local pull-request issue the verdict targets."
      t.string :pr_head_sha, null: false, comment: "PR head commit SHA the verdict was evaluated against."
      t.string :approved_design_revision, null: false,
        comment: "Feature's approved design revision the verdict was evaluated against."
      t.string :outcome, null: false, comment: "within_scope, material_drift, uncertain, or not_evaluated."
      t.datetime :recorded_at, null: false, comment: "When the verdict was recorded; the most recent row per issue is current."
      t.timestamps
    end

    add_column :intent_conformance_verdicts, :reviewer_run_id, :string, null: false, default: "",
      comment: "Identifier for the independent reviewer invocation that produced this verdict, for audit correlation."
    add_column :intent_conformance_verdicts, :reviewer_model, :string, null: false, default: "",
      comment: "Model used by the independent reviewer run."
    add_column :intent_conformance_verdicts, :cited_design_claims, :jsonb, null: false, default: [],
      comment: "Approved design claims the reviewer cited as relevant to this outcome."
    add_column :intent_conformance_verdicts, :cited_diff_locations, :jsonb, null: false, default: [],
      comment: "PR diff locations (file plus note) the reviewer cited as relevant to this outcome."
    add_column :intent_conformance_verdicts, :reasoning_summary, :text,
      comment: "Reviewer's free-text explanation of the outcome, for human review."

    add_index :intent_conformance_verdicts, %i[issue_id recorded_at],
      name: "index_intent_conformance_verdicts_on_issue_and_recorded_at"
    add_index :intent_conformance_verdicts, :outcome
  end

  def restore_decisions_verdict_foreign_key
    return unless table_exists?(:intent_conformance_decisions)

    # The decisions table belongs to this same release train and is empty
    # wherever this reshape runs, so FK validation scans nothing.
    safety_assured do
      add_foreign_key :intent_conformance_decisions, :intent_conformance_verdicts, column: :verdict_id
    end
  end

  # RLS is the documented exception to the Rails-helper rule (AGENTS.md):
  # PostgreSQL row-level security and CREATE POLICY have no equivalent
  # helper, so the SQL stays minimal and isolated to these blocks. Mirrors
  # EnableRlsOnIntentConformanceTables' issue-keyed verdict policy.
  def enable_rls_on_intent_conformance_verdicts
    safety_assured do
      execute "ALTER TABLE intent_conformance_verdicts ENABLE ROW LEVEL SECURITY"
      execute "ALTER TABLE intent_conformance_verdicts FORCE ROW LEVEL SECURITY"
      execute <<~SQL
        CREATE POLICY tenant_isolation ON intent_conformance_verdicts
        AS PERMISSIVE
        FOR ALL
        USING (
          paid_tenant_bypass() OR (
            EXISTS (
              SELECT 1 FROM issues
              INNER JOIN projects ON projects.id = issues.project_id
              WHERE issues.id = intent_conformance_verdicts.issue_id
                AND projects.account_id = paid_current_account_id()
            )
          )
        )
        WITH CHECK (
          paid_tenant_bypass() OR (
            EXISTS (
              SELECT 1 FROM issues
              INNER JOIN projects ON projects.id = issues.project_id
              WHERE issues.id = intent_conformance_verdicts.issue_id
                AND projects.account_id = paid_current_account_id()
            )
          )
        )
      SQL
    end
  end

  # Mirrors #3890's original project-keyed policy.
  def enable_rls_on_legacy_verdicts
    safety_assured do
      execute "ALTER TABLE intent_conformance_verdicts ENABLE ROW LEVEL SECURITY"
      execute "ALTER TABLE intent_conformance_verdicts FORCE ROW LEVEL SECURITY"
      execute <<~SQL
        CREATE POLICY tenant_isolation ON intent_conformance_verdicts
        AS PERMISSIVE
        FOR ALL
        USING (
          paid_tenant_bypass() OR EXISTS (
            SELECT 1 FROM projects
            WHERE projects.id = intent_conformance_verdicts.project_id
              AND projects.account_id = paid_current_account_id()
          )
        )
        WITH CHECK (
          paid_tenant_bypass() OR EXISTS (
            SELECT 1 FROM projects
            WHERE projects.id = intent_conformance_verdicts.project_id
              AND projects.account_id = paid_current_account_id()
          )
        )
      SQL
    end
  end
end
