# frozen_string_literal: true

# @spec INTENT-AMENDMENT-003
class CreateFeatureIntentsAndIssueLinks < ActiveRecord::Migration[8.1]
  def up
    create_table :feature_intents, comment: "RDR-066 feature intent: links a feature's approved design revision to its issue tree." do |t|
      t.references :project, null: false, foreign_key: true, index: true
      t.string :title, null: false, comment: "Human-readable feature name."
      t.text :brief, comment: "Feature brief the design was researched from."
      t.string :status, null: false, default: "design_open", comment: "Lifecycle status: discovering, design_open, needs_decision, ready_for_approval, approved_waiting_for_merge, released, revising, cancelled."
      t.string :approved_design_revision, comment: "Merged repository revision of the currently approved design."
      t.datetime :approved_revision_recorded_at, comment: "When the approved design revision was recorded."
      t.timestamps
    end

    add_index :feature_intents, :status
    add_index :feature_intents, %i[project_id status]

    create_table :feature_intent_issues, comment: "Links feature intent records to their issue trees (implementation issues and PR issues)." do |t|
      t.references :feature_intent, null: false, foreign_key: true, index: true
      t.references :issue, null: false, foreign_key: true, index: { unique: true }
      t.timestamps
    end

    # RLS is the documented exception to the Rails-helper rule (AGENTS.md):
    # PostgreSQL row-level security and CREATE POLICY have no equivalent
    # helper, so the SQL stays minimal and isolated to this block.
    safety_assured do
      execute <<~SQL
        ALTER TABLE feature_intents ENABLE ROW LEVEL SECURITY;
        ALTER TABLE feature_intents FORCE ROW LEVEL SECURITY;
        CREATE POLICY tenant_isolation ON feature_intents
          AS PERMISSIVE FOR ALL
          USING (
            paid_tenant_bypass() OR EXISTS (
              SELECT 1 FROM projects
              WHERE projects.id = feature_intents.project_id
                AND projects.account_id = paid_current_account_id()
            )
          )
          WITH CHECK (
            paid_tenant_bypass() OR EXISTS (
              SELECT 1 FROM projects
              WHERE projects.id = feature_intents.project_id
                AND projects.account_id = paid_current_account_id()
            )
          );
      SQL

      execute <<~SQL
        ALTER TABLE feature_intent_issues ENABLE ROW LEVEL SECURITY;
        ALTER TABLE feature_intent_issues FORCE ROW LEVEL SECURITY;
        CREATE POLICY tenant_isolation ON feature_intent_issues
          AS PERMISSIVE FOR ALL
          USING (
            paid_tenant_bypass() OR EXISTS (
              SELECT 1 FROM feature_intents
              INNER JOIN projects ON projects.id = feature_intents.project_id
              WHERE feature_intents.id = feature_intent_issues.feature_intent_id
                AND projects.account_id = paid_current_account_id()
            )
          )
          WITH CHECK (
            paid_tenant_bypass() OR EXISTS (
              SELECT 1 FROM feature_intents
              INNER JOIN projects ON projects.id = feature_intents.project_id
              WHERE feature_intents.id = feature_intent_issues.feature_intent_id
                AND projects.account_id = paid_current_account_id()
            )
          );
      SQL
    end
  end

  def down
    safety_assured do
      execute "DROP POLICY IF EXISTS tenant_isolation ON feature_intent_issues"
      execute "ALTER TABLE feature_intent_issues NO FORCE ROW LEVEL SECURITY"
      execute "ALTER TABLE feature_intent_issues DISABLE ROW LEVEL SECURITY"

      execute "DROP POLICY IF EXISTS tenant_isolation ON feature_intents"
      execute "ALTER TABLE feature_intents NO FORCE ROW LEVEL SECURITY"
      execute "ALTER TABLE feature_intents DISABLE ROW LEVEL SECURITY"
    end

    drop_table :feature_intent_issues
    drop_table :feature_intents
  end
end
