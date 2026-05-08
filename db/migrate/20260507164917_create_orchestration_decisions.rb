# frozen_string_literal: true

class CreateOrchestrationDecisions < ActiveRecord::Migration[8.1]
  def up
    create_table :orchestration_decisions,
      comment: "Structured log of orchestration decisions for later workflow analysis and learning." do |t|
      t.references :project,
        null: false,
        index: false,
        foreign_key: { on_delete: :cascade },
        comment: "Owning project for tenant isolation and project-level analysis."
      t.references :agent_run,
        null: true,
        index: false,
        foreign_key: { on_delete: :nullify },
        comment: "Agent run whose workflow emitted the decision when a specific run exists."
      t.string :decision_type,
        null: false,
        limit: 100,
        comment: "Decision category such as decompose, select_agent, parallelize, retry, or escalate."
      t.string :actor,
        null: false,
        limit: 100,
        comment: "Component or role that made the decision, such as workflow, planner, scheduler, or human."
      t.jsonb :context,
        null: false,
        default: {},
        comment: "Context snapshot used to make the decision, typically issue, project, and workflow features."
      t.jsonb :inputs,
        null: false,
        default: {},
        comment: "Structured inputs or options considered before the decision."
      t.jsonb :outputs,
        null: false,
        default: {},
        comment: "Structured payload describing what the workflow decided."
      t.jsonb :outcome_references,
        null: false,
        default: [],
        comment: "References to later runs, metrics, or artifacts used to attribute outcomes back to this decision."
      t.timestamps
    end

    add_index :orchestration_decisions,
      [ :project_id, :created_at, :id ],
      name: "idx_orchestration_decisions_project_recent"
    add_index :orchestration_decisions,
      [ :project_id, :decision_type, :created_at ],
      name: "idx_orchestration_decisions_project_type_created"
    add_index :orchestration_decisions,
      [ :agent_run_id, :created_at, :id ],
      name: "idx_orchestration_decisions_run_recent"
    add_index :orchestration_decisions,
      [ :agent_run_id, :decision_type, :created_at ],
      name: "idx_orchestration_decisions_run_type_created"
    add_index :orchestration_decisions,
      [ :project_id, :actor, :created_at ],
      name: "idx_orchestration_decisions_project_actor_created"

    execute <<~SQL
      ALTER TABLE orchestration_decisions ENABLE ROW LEVEL SECURITY;
      ALTER TABLE orchestration_decisions FORCE ROW LEVEL SECURITY;
      CREATE POLICY tenant_isolation ON orchestration_decisions
        USING (
          paid_tenant_bypass() OR EXISTS (
            SELECT 1 FROM projects
            WHERE projects.id = orchestration_decisions.project_id
              AND projects.account_id = paid_current_account_id()
          )
        )
        WITH CHECK (
          paid_tenant_bypass() OR EXISTS (
            SELECT 1 FROM projects
            WHERE projects.id = orchestration_decisions.project_id
              AND projects.account_id = paid_current_account_id()
          )
        );
    SQL
  end

  def down
    # Acquire dependent table locks up front so rollback does not deadlock with
    # concurrent metadata reads that already hold project/agent_run locks.
    execute <<~SQL
      LOCK TABLE projects, agent_runs IN ACCESS SHARE MODE;
      LOCK TABLE orchestration_decisions IN ACCESS EXCLUSIVE MODE;
    SQL

    execute "DROP POLICY IF EXISTS tenant_isolation ON orchestration_decisions"
    execute "ALTER TABLE orchestration_decisions NO FORCE ROW LEVEL SECURITY"
    execute "ALTER TABLE orchestration_decisions DISABLE ROW LEVEL SECURITY"

    drop_table :orchestration_decisions
  end
end
