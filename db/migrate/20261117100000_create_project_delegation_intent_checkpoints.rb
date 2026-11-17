# frozen_string_literal: true

# @spec PROJECT-DELEGATION-002
class CreateProjectDelegationIntentCheckpoints < ActiveRecord::Migration[8.1]
  def up
    create_table :project_delegation_intent_checkpoints,
      comment: "Grouped material intent questions and their immutable settlement binding." do |t|
      t.references :feature_intent, null: false, foreign_key: true
      t.string :status, null: false, default: "open"
      t.text :recommendation, null: false
      t.jsonb :alternatives, null: false, default: []
      t.jsonb :consequences, null: false, default: []
      t.jsonb :affected_scope, null: false, default: {}
      t.jsonb :evidence, null: false, default: []
      t.string :proposed_design_revision
      t.string :proposed_acceptance_revision
      t.timestamps
    end

    add_index :project_delegation_intent_checkpoints, %i[feature_intent_id status],
      name: "index_project_delegation_checkpoints_on_intent_and_status"

    # This column is added to a hot existing table. The association is still
    # tenant-scoped and enforced by the application; a later online migration
    # can add a validated foreign key without blocking decision writes.
    add_reference :feature_intent_decisions, :intent_checkpoint, foreign_key: false, index: false

    create_table :project_delegation_intent_settlements,
      comment: "Append-only human settlement bound to exact design and acceptance revisions." do |t|
      t.references :intent_checkpoint, null: false, foreign_key: { to_table: :project_delegation_intent_checkpoints }
      t.references :settled_by, null: false, foreign_key: { to_table: :users }
      t.string :disposition, null: false
      t.jsonb :answers, null: false, default: {}
      t.string :design_revision, null: false
      t.string :acceptance_revision, null: false
      t.datetime :settled_at, null: false
      t.timestamps
    end

    add_index :project_delegation_intent_settlements, %i[intent_checkpoint_id created_at],
      name: "idx_pd_intent_settlements_checkpoint_created"

    safety_assured do
      execute <<~SQL
        ALTER TABLE project_delegation_intent_checkpoints ENABLE ROW LEVEL SECURITY;
        ALTER TABLE project_delegation_intent_checkpoints FORCE ROW LEVEL SECURITY;
        CREATE POLICY tenant_isolation ON project_delegation_intent_checkpoints
          AS PERMISSIVE FOR ALL
          USING (paid_tenant_bypass() OR EXISTS (
            SELECT 1 FROM feature_intents
            INNER JOIN projects ON projects.id = feature_intents.project_id
            WHERE feature_intents.id = project_delegation_intent_checkpoints.feature_intent_id
              AND projects.account_id = paid_current_account_id()
          ))
          WITH CHECK (paid_tenant_bypass() OR EXISTS (
            SELECT 1 FROM feature_intents
            INNER JOIN projects ON projects.id = feature_intents.project_id
            WHERE feature_intents.id = project_delegation_intent_checkpoints.feature_intent_id
              AND projects.account_id = paid_current_account_id()
          ));
        ALTER TABLE project_delegation_intent_settlements ENABLE ROW LEVEL SECURITY;
        ALTER TABLE project_delegation_intent_settlements FORCE ROW LEVEL SECURITY;
        CREATE POLICY tenant_isolation ON project_delegation_intent_settlements
          AS PERMISSIVE FOR ALL
          USING (paid_tenant_bypass() OR EXISTS (
            SELECT 1 FROM project_delegation_intent_checkpoints
            INNER JOIN feature_intents ON feature_intents.id = project_delegation_intent_checkpoints.feature_intent_id
            INNER JOIN projects ON projects.id = feature_intents.project_id
            WHERE project_delegation_intent_checkpoints.id = project_delegation_intent_settlements.intent_checkpoint_id
              AND projects.account_id = paid_current_account_id()
          ))
          WITH CHECK (paid_tenant_bypass() OR EXISTS (
            SELECT 1 FROM project_delegation_intent_checkpoints
            INNER JOIN feature_intents ON feature_intents.id = project_delegation_intent_checkpoints.feature_intent_id
            INNER JOIN projects ON projects.id = feature_intents.project_id
            WHERE project_delegation_intent_checkpoints.id = project_delegation_intent_settlements.intent_checkpoint_id
              AND projects.account_id = paid_current_account_id()
          ));
      SQL
    end

    create_function :prevent_project_delegation_intent_settlement_mutation, version: 1
    create_trigger :prevent_project_delegation_intent_settlement_update,
      on: :project_delegation_intent_settlements
    create_trigger :prevent_project_delegation_intent_settlement_delete,
      on: :project_delegation_intent_settlements
  end

  def down
    safety_assured do
      execute "DROP TRIGGER IF EXISTS prevent_project_delegation_intent_settlement_update ON project_delegation_intent_settlements"
      execute "DROP TRIGGER IF EXISTS prevent_project_delegation_intent_settlement_delete ON project_delegation_intent_settlements"
      execute "DROP FUNCTION IF EXISTS prevent_project_delegation_intent_settlement_mutation()"
      execute "DROP POLICY IF EXISTS tenant_isolation ON project_delegation_intent_settlements"
      execute "DROP POLICY IF EXISTS tenant_isolation ON project_delegation_intent_checkpoints"
    end
    remove_reference :feature_intent_decisions, :intent_checkpoint if column_exists?(:feature_intent_decisions, :intent_checkpoint_id)
    drop_table :project_delegation_intent_settlements
    drop_table :project_delegation_intent_checkpoints
  end
end
