# frozen_string_literal: true

# @spec PROJECT-DELEGATION-002
class CreateDelegationIntentCheckpoints < ActiveRecord::Migration[8.1]
  def up
    create_table :delegation_intent_checkpoints,
      comment: "RDR-080 settled-intent checkpoint: one reviewable group of material product questions for a work item, bound to the design and acceptance revisions used for delegated admission." do |t|
      t.references :account, null: false, foreign_key: true
      t.references :project, null: false, foreign_key: true
      t.references :issue, null: false, foreign_key: true
      t.references :feature_intent, foreign_key: true
      t.string :status, null: false, default: "pending", comment: "pending, settled, rejected, superseded."
      t.string :design_revision, null: false, comment: "Design revision the checkpoint binds: the feature's approved design revision, or the work item's intent-revision digest."
      t.string :acceptance_revision, null: false, comment: "Acceptance criteria digest the checkpoint binds; matches the delegated-admission acceptance token."
      t.string :evidence_revision, comment: "Closeout-evidence digest the checkpoint was planned against."
      t.jsonb :question_groups, null: false, default: [], comment: "Grouped material questions with question, recommendation, alternatives, consequences, affected scope, and evidence."
      t.string :question_set_digest, null: false, comment: "Digest of the grouped question identities; changes open a fresh checkpoint."
      t.references :created_by, foreign_key: { to_table: :users }

      t.timestamps
    end

    add_index :delegation_intent_checkpoints, %i[issue_id status question_set_digest design_revision acceptance_revision],
      unique: true, name: "index_delegation_intent_checkpoints_identity"
    add_index :delegation_intent_checkpoints, :issue_id,
      unique: true, where: "status = 'pending'", name: "index_delegation_intent_checkpoints_one_pending_per_issue"

    create_table :delegation_intent_settlements,
      comment: "Immutable RDR-080 intent-checkpoint settlement: the human's settled answers or rejection, bound to the design and acceptance revisions." do |t|
      t.references :delegation_intent_checkpoint, null: false, foreign_key: true
      t.string :disposition, null: false, comment: "settled, rejected, or amended."
      t.jsonb :answers, null: false, default: [], comment: "Per-group answers or amendments: group_key, answer, and optional amendment note."
      t.string :design_revision, null: false, comment: "Design revision copied from the checkpoint at settlement; append-only."
      t.string :acceptance_revision, null: false, comment: "Acceptance revision copied from the checkpoint at settlement; append-only."
      t.references :settled_by, null: false, foreign_key: { to_table: :users }
      t.datetime :settled_at, null: false, comment: "When the authorized human settled, rejected, or amended the group."

      t.timestamps
    end

    add_index :delegation_intent_settlements, :delegation_intent_checkpoint_id,
      unique: true, name: "index_delegation_intent_settlements_one_per_checkpoint"

    # RLS is the documented exception to the Rails-helper rule (AGENTS.md):
    # PostgreSQL row-level security and CREATE POLICY have no equivalent
    # helper, so the SQL stays minimal and isolated to these blocks.
    safety_assured do
      execute <<~SQL
        ALTER TABLE delegation_intent_checkpoints ENABLE ROW LEVEL SECURITY;
        ALTER TABLE delegation_intent_checkpoints FORCE ROW LEVEL SECURITY;
        CREATE POLICY tenant_isolation ON delegation_intent_checkpoints
          AS PERMISSIVE FOR ALL
          USING (
            paid_tenant_bypass() OR EXISTS (
              SELECT 1 FROM projects
              WHERE projects.id = delegation_intent_checkpoints.project_id
                AND projects.account_id = paid_current_account_id()
            )
          )
          WITH CHECK (
            paid_tenant_bypass() OR EXISTS (
              SELECT 1 FROM projects
              WHERE projects.id = delegation_intent_checkpoints.project_id
                AND projects.account_id = paid_current_account_id()
            )
          );

        ALTER TABLE delegation_intent_settlements ENABLE ROW LEVEL SECURITY;
        ALTER TABLE delegation_intent_settlements FORCE ROW LEVEL SECURITY;
        CREATE POLICY tenant_isolation ON delegation_intent_settlements
          AS PERMISSIVE FOR ALL
          USING (
            paid_tenant_bypass() OR EXISTS (
              SELECT 1 FROM delegation_intent_checkpoints
              INNER JOIN projects ON projects.id = delegation_intent_checkpoints.project_id
              WHERE delegation_intent_checkpoints.id = delegation_intent_settlements.delegation_intent_checkpoint_id
                AND projects.account_id = paid_current_account_id()
            )
          )
          WITH CHECK (
            paid_tenant_bypass() OR EXISTS (
              SELECT 1 FROM delegation_intent_checkpoints
              INNER JOIN projects ON projects.id = delegation_intent_checkpoints.project_id
              WHERE delegation_intent_checkpoints.id = delegation_intent_settlements.delegation_intent_checkpoint_id
                AND projects.account_id = paid_current_account_id()
            )
          );
      SQL
    end

    create_function :prevent_delegation_intent_settlement_mutation, version: 1
    create_trigger :prevent_delegation_intent_settlement_update, on: :delegation_intent_settlements
    create_trigger :prevent_delegation_intent_settlement_delete, on: :delegation_intent_settlements
  end

  def down
    safety_assured do
      execute "DROP TRIGGER IF EXISTS prevent_delegation_intent_settlement_update ON delegation_intent_settlements"
      execute "DROP TRIGGER IF EXISTS prevent_delegation_intent_settlement_delete ON delegation_intent_settlements"
      drop_function :prevent_delegation_intent_settlement_mutation, version: 1
      execute "DROP POLICY IF EXISTS tenant_isolation ON delegation_intent_settlements"
      execute "ALTER TABLE delegation_intent_settlements NO FORCE ROW LEVEL SECURITY"
      execute "ALTER TABLE delegation_intent_settlements DISABLE ROW LEVEL SECURITY"
      execute "DROP POLICY IF EXISTS tenant_isolation ON delegation_intent_checkpoints"
      execute "ALTER TABLE delegation_intent_checkpoints NO FORCE ROW LEVEL SECURITY"
      execute "ALTER TABLE delegation_intent_checkpoints DISABLE ROW LEVEL SECURITY"
    end

    drop_table :delegation_intent_settlements
    drop_table :delegation_intent_checkpoints
  end
end
