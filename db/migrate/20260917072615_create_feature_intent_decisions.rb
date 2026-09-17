# frozen_string_literal: true

# @spec FEATURE-APPROVAL-006 @spec FEATURE-APPROVAL-007
class CreateFeatureIntentDecisions < ActiveRecord::Migration[8.1]
  def up
    create_table :feature_intent_decisions, comment: "RDR-066 open product decisions for a feature intent: clarifying questions and AI-inferred decisions awaiting human confirmation." do |t|
      t.references :feature_intent, null: false, foreign_key: true
      t.string :kind, null: false, comment: "question or inferred_decision."
      t.text :design_claim, null: false, comment: "The design claim this decision affects, so the Inbox can explain what it holds."
      t.text :prompt, null: false, comment: "The question text, or the inferred decision's stated assumption."
      t.string :status, null: false, default: "open", comment: "open or resolved. For inferred_decision, resolved means human-confirmed."
      t.text :answer, comment: "Human's answer or confirmation note."
      t.references :resolved_by, foreign_key: { to_table: :users }
      t.datetime :resolved_at
      t.timestamps
    end

    add_index :feature_intent_decisions, :status
    add_index :feature_intent_decisions, %i[feature_intent_id status]

    # RLS is the documented exception to the Rails-helper rule (AGENTS.md):
    # PostgreSQL row-level security and CREATE POLICY have no equivalent
    # helper, so the SQL stays minimal and isolated to this block.
    safety_assured do
      execute <<~SQL
        ALTER TABLE feature_intent_decisions ENABLE ROW LEVEL SECURITY;
        ALTER TABLE feature_intent_decisions FORCE ROW LEVEL SECURITY;
        CREATE POLICY tenant_isolation ON feature_intent_decisions
          AS PERMISSIVE FOR ALL
          USING (
            paid_tenant_bypass() OR EXISTS (
              SELECT 1 FROM feature_intents
              INNER JOIN projects ON projects.id = feature_intents.project_id
              WHERE feature_intents.id = feature_intent_decisions.feature_intent_id
                AND projects.account_id = paid_current_account_id()
            )
          )
          WITH CHECK (
            paid_tenant_bypass() OR EXISTS (
              SELECT 1 FROM feature_intents
              INNER JOIN projects ON projects.id = feature_intents.project_id
              WHERE feature_intents.id = feature_intent_decisions.feature_intent_id
                AND projects.account_id = paid_current_account_id()
            )
          );
      SQL
    end
  end

  def down
    safety_assured do
      execute "DROP POLICY IF EXISTS tenant_isolation ON feature_intent_decisions"
      execute "ALTER TABLE feature_intent_decisions NO FORCE ROW LEVEL SECURITY"
      execute "ALTER TABLE feature_intent_decisions DISABLE ROW LEVEL SECURITY"
    end

    drop_table :feature_intent_decisions
  end
end
