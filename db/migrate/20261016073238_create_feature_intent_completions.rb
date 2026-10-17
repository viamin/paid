# frozen_string_literal: true

class CreateFeatureIntentCompletions < ActiveRecord::Migration[8.1]
  def up
    create_table :feature_intent_completions, comment: "Completion-cycle state and remote-write receipts for confidence-driven feature delivery." do |t|
      t.references :feature_intent, null: false, foreign_key: true, index: { unique: true }
      t.references :completion_issue, foreign_key: { to_table: :issues }
      t.string :status, null: false, default: "pending", comment: "pending while forward work or remote writes remain; complete only after a verified closeout."
      t.integer :cycle, null: false, default: 1, comment: "Monotonic completion cycle, incremented when a post-completion finding reopens work."
      t.integer :findings_generation, null: false, default: 0
      t.jsonb :pending_operations, null: false, default: {}, comment: "Durable remote-write intents that block a completion claim until read back."
      t.jsonb :release_readiness, null: false, default: {}, comment: "Acceptance, isolation, and release-authorization evidence for the current cycle."
      t.datetime :completed_at
      t.timestamps null: false
    end

    create_table :feature_intent_forward_work_items, comment: "Idempotent findings routed to an unstarted issue or a completion-blocking follow-up." do |t|
      t.references :feature_intent_completion, null: false, foreign_key: true, index: { name: "index_forward_work_on_completion" }
      t.references :affected_issue, foreign_key: { to_table: :issues }
      t.references :follow_up_issue, foreign_key: { to_table: :issues }
      t.string :fingerprint, null: false, limit: 64, comment: "Stable finding identity supplied by the assessment pipeline."
      t.jsonb :finding, null: false, default: {}
      t.string :status, null: false, default: "pending"
      t.timestamps null: false
    end

    add_index :feature_intent_forward_work_items, [ :feature_intent_completion_id, :fingerprint ], unique: true,
      name: "index_forward_work_on_completion_and_fingerprint"
    add_check_constraint :feature_intent_completions, "status IN ('pending', 'complete')", name: "chk_feature_intent_completions_status"
    add_check_constraint :feature_intent_completions, "cycle > 0", name: "chk_feature_intent_completions_cycle"
    add_check_constraint :feature_intent_forward_work_items, "status IN ('pending', 'applied')", name: "chk_forward_work_items_status"

    safety_assured do
      execute <<~SQL
        ALTER TABLE feature_intent_completions ENABLE ROW LEVEL SECURITY;
        ALTER TABLE feature_intent_completions FORCE ROW LEVEL SECURITY;
        CREATE POLICY tenant_isolation ON feature_intent_completions
          AS PERMISSIVE FOR ALL
          USING (paid_tenant_bypass() OR EXISTS (
            SELECT 1 FROM feature_intents INNER JOIN projects ON projects.id = feature_intents.project_id
            WHERE feature_intents.id = feature_intent_completions.feature_intent_id
              AND projects.account_id = paid_current_account_id()
          ))
          WITH CHECK (paid_tenant_bypass() OR EXISTS (
            SELECT 1 FROM feature_intents INNER JOIN projects ON projects.id = feature_intents.project_id
            WHERE feature_intents.id = feature_intent_completions.feature_intent_id
              AND projects.account_id = paid_current_account_id()
          ));

        ALTER TABLE feature_intent_forward_work_items ENABLE ROW LEVEL SECURITY;
        ALTER TABLE feature_intent_forward_work_items FORCE ROW LEVEL SECURITY;
        CREATE POLICY tenant_isolation ON feature_intent_forward_work_items
          AS PERMISSIVE FOR ALL
          USING (paid_tenant_bypass() OR EXISTS (
            SELECT 1 FROM feature_intent_completions
            INNER JOIN feature_intents ON feature_intents.id = feature_intent_completions.feature_intent_id
            INNER JOIN projects ON projects.id = feature_intents.project_id
            WHERE feature_intent_completions.id = feature_intent_forward_work_items.feature_intent_completion_id
              AND projects.account_id = paid_current_account_id()
          ))
          WITH CHECK (paid_tenant_bypass() OR EXISTS (
            SELECT 1 FROM feature_intent_completions
            INNER JOIN feature_intents ON feature_intents.id = feature_intent_completions.feature_intent_id
            INNER JOIN projects ON projects.id = feature_intents.project_id
            WHERE feature_intent_completions.id = feature_intent_forward_work_items.feature_intent_completion_id
              AND projects.account_id = paid_current_account_id()
          ));
      SQL
    end
  end

  def down
    safety_assured do
      execute "DROP POLICY IF EXISTS tenant_isolation ON feature_intent_forward_work_items"
      execute "ALTER TABLE feature_intent_forward_work_items NO FORCE ROW LEVEL SECURITY"
      execute "ALTER TABLE feature_intent_forward_work_items DISABLE ROW LEVEL SECURITY"
      execute "DROP POLICY IF EXISTS tenant_isolation ON feature_intent_completions"
      execute "ALTER TABLE feature_intent_completions NO FORCE ROW LEVEL SECURITY"
      execute "ALTER TABLE feature_intent_completions DISABLE ROW LEVEL SECURITY"
    end
    drop_table :feature_intent_forward_work_items
    drop_table :feature_intent_completions
  end
end
