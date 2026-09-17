# frozen_string_literal: true

# @spec FEATURE-APPROVAL-008
class CreateFeatureIntentDesignPrs < ActiveRecord::Migration[8.1]
  def up
    create_table :feature_intent_design_prs, comment: "RDR-066 design PRs (RDR and/or LID Planning) linked to a feature intent, tracked for staleness and required-artifact checks." do |t|
      t.references :feature_intent, null: false, foreign_key: true
      t.integer :pull_request_number, null: false
      t.string :design_pr_kind, null: false, comment: "rdr or lid_planning."
      t.boolean :required, null: false, default: true, comment: "Whether this artifact must merge before the feature can release, per the project's LID mode."
      t.string :head_sha, null: false, comment: "Most recently synced PR head SHA."
      t.string :reviewed_head_sha, comment: "Head SHA the feature's current open decisions/evidence were generated against. When it differs from head_sha, the PR moved after discovery and approval is held until Paid re-evaluates the new head."
      t.datetime :merged_at
      t.timestamps
    end

    add_index :feature_intent_design_prs, %i[feature_intent_id pull_request_number], unique: true, name: "index_feature_intent_design_prs_unique_pr"

    # RLS is the documented exception to the Rails-helper rule (AGENTS.md):
    # PostgreSQL row-level security and CREATE POLICY have no equivalent
    # helper, so the SQL stays minimal and isolated to this block.
    safety_assured do
      execute <<~SQL
        ALTER TABLE feature_intent_design_prs ENABLE ROW LEVEL SECURITY;
        ALTER TABLE feature_intent_design_prs FORCE ROW LEVEL SECURITY;
        CREATE POLICY tenant_isolation ON feature_intent_design_prs
          AS PERMISSIVE FOR ALL
          USING (
            paid_tenant_bypass() OR EXISTS (
              SELECT 1 FROM feature_intents
              INNER JOIN projects ON projects.id = feature_intents.project_id
              WHERE feature_intents.id = feature_intent_design_prs.feature_intent_id
                AND projects.account_id = paid_current_account_id()
            )
          )
          WITH CHECK (
            paid_tenant_bypass() OR EXISTS (
              SELECT 1 FROM feature_intents
              INNER JOIN projects ON projects.id = feature_intents.project_id
              WHERE feature_intents.id = feature_intent_design_prs.feature_intent_id
                AND projects.account_id = paid_current_account_id()
            )
          );
      SQL
    end
  end

  def down
    safety_assured do
      execute "DROP POLICY IF EXISTS tenant_isolation ON feature_intent_design_prs"
      execute "ALTER TABLE feature_intent_design_prs NO FORCE ROW LEVEL SECURITY"
      execute "ALTER TABLE feature_intent_design_prs DISABLE ROW LEVEL SECURITY"
    end

    drop_table :feature_intent_design_prs
  end
end
