# frozen_string_literal: true

# @spec INTENT-MERGE-GUARD-002 @spec INTENT-MERGE-GUARD-003 @spec INTENT-MERGE-GUARD-004
class CreateIntentConformanceVerdicts < ActiveRecord::Migration[8.1]
  def up
    create_table :intent_conformance_verdicts, comment: "RDR-067 intent-conformance verdict identity: outcome bound to an exact PR head and approved design revision." do |t|
      t.references :project, null: false, foreign_key: true
      t.references :issue, null: false, foreign_key: true, comment: "Local pull-request issue the verdict targets."
      t.string :pr_head_sha, null: false, comment: "PR head commit SHA the verdict was evaluated against."
      t.string :approved_design_revision, null: false, comment: "Feature's approved design revision the verdict was evaluated against."
      t.string :outcome, null: false, comment: "within_scope, material_drift, uncertain, or not_evaluated."
      t.datetime :recorded_at, null: false, comment: "When the verdict was recorded; the most recent row per issue is current."
      t.timestamps
    end

    add_index :intent_conformance_verdicts, %i[issue_id recorded_at], name: "index_intent_conformance_verdicts_on_issue_and_recorded_at"
    add_index :intent_conformance_verdicts, :outcome

    # RLS is the documented exception to the Rails-helper rule (AGENTS.md):
    # PostgreSQL row-level security and CREATE POLICY have no equivalent
    # helper, so the SQL stays minimal and isolated to this block.
    safety_assured do
      execute <<~SQL
        ALTER TABLE intent_conformance_verdicts ENABLE ROW LEVEL SECURITY;
        ALTER TABLE intent_conformance_verdicts FORCE ROW LEVEL SECURITY;
        CREATE POLICY tenant_isolation ON intent_conformance_verdicts
          AS PERMISSIVE FOR ALL
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
          );
      SQL
    end
  end

  def down
    safety_assured do
      execute "DROP POLICY IF EXISTS tenant_isolation ON intent_conformance_verdicts"
      execute "ALTER TABLE intent_conformance_verdicts NO FORCE ROW LEVEL SECURITY"
      execute "ALTER TABLE intent_conformance_verdicts DISABLE ROW LEVEL SECURITY"
    end

    drop_table :intent_conformance_verdicts
  end
end
