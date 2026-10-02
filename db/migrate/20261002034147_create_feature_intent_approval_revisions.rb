# frozen_string_literal: true

# @spec FEATURE-APPROVAL-014 @spec FEATURE-APPROVAL-016
class CreateFeatureIntentApprovalRevisions < ActiveRecord::Migration[8.1]
  def up
    create_table :feature_intent_approval_revisions, comment: "Immutable RDR-066 approval snapshots for feature intent design revisions." do |t|
      t.references :feature_intent, null: false, foreign_key: true
      t.references :approved_by, null: false, foreign_key: { to_table: :users }
      t.datetime :approved_at, null: false, comment: "When the authorized human approved this design revision."
      t.string :source, null: false, comment: "Approval source, such as inbox or direct_github_merge."
      t.jsonb :pr_heads, null: false, default: {}, comment: "Exact design PR number => head SHA snapshot approved by the human."
      t.integer :revision_number, null: false, comment: "Feature-local immutable approval revision sequence."

      t.timestamps
    end

    add_index :feature_intent_approval_revisions, %i[feature_intent_id revision_number], unique: true,
      name: "index_feature_intent_approval_revisions_unique_revision"

    safety_assured do
      execute <<~SQL
        ALTER TABLE feature_intent_approval_revisions ENABLE ROW LEVEL SECURITY;
        ALTER TABLE feature_intent_approval_revisions FORCE ROW LEVEL SECURITY;
        CREATE POLICY tenant_isolation ON feature_intent_approval_revisions
          AS PERMISSIVE FOR ALL
          USING (
            paid_tenant_bypass() OR EXISTS (
              SELECT 1 FROM feature_intents
              INNER JOIN projects ON projects.id = feature_intents.project_id
              WHERE feature_intents.id = feature_intent_approval_revisions.feature_intent_id
                AND projects.account_id = paid_current_account_id()
            )
          )
          WITH CHECK (
            paid_tenant_bypass() OR EXISTS (
              SELECT 1 FROM feature_intents
              INNER JOIN projects ON projects.id = feature_intents.project_id
              WHERE feature_intents.id = feature_intent_approval_revisions.feature_intent_id
                AND projects.account_id = paid_current_account_id()
            )
          );
      SQL
    end
  end

  def down
    safety_assured do
      execute "DROP POLICY IF EXISTS tenant_isolation ON feature_intent_approval_revisions"
      execute "ALTER TABLE feature_intent_approval_revisions NO FORCE ROW LEVEL SECURITY"
      execute "ALTER TABLE feature_intent_approval_revisions DISABLE ROW LEVEL SECURITY"
    end

    drop_table :feature_intent_approval_revisions
  end
end
