# frozen_string_literal: true

# @spec PROJECT-DELEGATION-002
class CreateIntentCheckpoints < ActiveRecord::Migration[8.1]
  def up
    create_table :intent_checkpoints, comment: "RDR-080 grouped material-question checkpoints; settlements bind immutable answers to the design and acceptance revision." do |t|
      t.references :account, null: false, foreign_key: true
      t.references :project, null: false, foreign_key: true
      t.references :issue, null: false, foreign_key: true
      t.references :feature_intent, foreign_key: true
      t.references :settled_by, foreign_key: { to_table: :users }
      t.string :status, null: false, default: "pending", comment: "pending, settled, rejected, or superseded. settled/rejected are terminal and append-only."
      t.jsonb :groups, null: false, default: [], comment: "Grouped material questions: key, questions, recommendation, alternatives, consequences, affected scope, evidence."
      t.jsonb :answers, null: false, default: {}, comment: "Immutable human answers keyed by group key, bound at settlement."
      t.string :disposition, comment: "Human disposition recorded at settlement: settled, amended, or rejected."
      t.string :design_revision, comment: "Design revision token the settlement is bound to."
      t.string :acceptance_revision, comment: "Acceptance revision token the settlement is bound to."
      t.datetime :settled_at
      t.timestamps
    end

    add_index :intent_checkpoints, %i[issue_id status], name: "index_intent_checkpoints_on_issue_and_status"
    add_index :intent_checkpoints, [ :issue_id ],
      name: "index_intent_checkpoints_one_pending_per_issue",
      unique: true,
      where: "status = 'pending'"
    add_index :intent_checkpoints, [ :project_id, :status ], name: "index_intent_checkpoints_on_project_and_status"

    enable_tenant_rls

    create_function :prevent_intent_checkpoint_terminal_mutation, version: 1
    create_trigger :prevent_intent_checkpoint_terminal_update, on: :intent_checkpoints
    create_trigger :prevent_intent_checkpoint_terminal_delete, on: :intent_checkpoints
  end

  def down
    drop_trigger :prevent_intent_checkpoint_terminal_update, on: :intent_checkpoints
    drop_trigger :prevent_intent_checkpoint_terminal_delete, on: :intent_checkpoints
    drop_function :prevent_intent_checkpoint_terminal_mutation

    disable_tenant_rls
    drop_table :intent_checkpoints
  end

  private

  def enable_tenant_rls
    safety_assured do
      execute "ALTER TABLE intent_checkpoints ENABLE ROW LEVEL SECURITY"
      execute "ALTER TABLE intent_checkpoints FORCE ROW LEVEL SECURITY"
      execute "DROP POLICY IF EXISTS tenant_isolation ON intent_checkpoints"
      execute <<~SQL
        CREATE POLICY tenant_isolation ON intent_checkpoints
        AS PERMISSIVE
        FOR ALL
        USING (paid_tenant_bypass() OR (#{tenant_condition}))
        WITH CHECK (paid_tenant_bypass() OR (#{tenant_condition}))
      SQL
    end
  end

  def disable_tenant_rls
    safety_assured do
      execute "DROP POLICY IF EXISTS tenant_isolation ON intent_checkpoints"
      execute "ALTER TABLE intent_checkpoints NO FORCE ROW LEVEL SECURITY"
      execute "ALTER TABLE intent_checkpoints DISABLE ROW LEVEL SECURITY"
    end
  end

  def tenant_condition
    <<~SQL.squish
      intent_checkpoints.account_id = paid_current_account_id()
      AND EXISTS (
        SELECT 1 FROM projects
        WHERE projects.id = intent_checkpoints.project_id
          AND projects.account_id = paid_current_account_id()
      )
      AND EXISTS (
        SELECT 1 FROM issues
        INNER JOIN projects AS issue_projects ON issue_projects.id = issues.project_id
        WHERE issues.id = intent_checkpoints.issue_id
          AND issues.project_id = intent_checkpoints.project_id
          AND issue_projects.account_id = paid_current_account_id()
      )
      AND (
        intent_checkpoints.settled_by_id IS NULL
        OR EXISTS (
          SELECT 1 FROM users
          WHERE users.id = intent_checkpoints.settled_by_id
            AND users.account_id = paid_current_account_id()
        )
      )
    SQL
  end
end
