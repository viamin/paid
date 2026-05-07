# frozen_string_literal: true

class CreateOrchestrationDecisionEvents < ActiveRecord::Migration[8.1]
  def change
    create_table :orchestration_decision_events do |t|
      t.references :project,
        null: false,
        foreign_key: true,
        comment: "Project owning the orchestration decision event."
      t.references :issue,
        null: true,
        foreign_key: true,
        comment: "Optional PR or issue the decision was evaluated against."
      t.references :agent_run,
        null: true,
        foreign_key: true,
        comment: "Optional agent run whose lifecycle changed because of the decision."
      t.string :decision_point,
        null: false,
        comment: "Named workflow, activity, job, or controller branch that made the decision."
      t.string :action,
        null: false,
        comment: "Selected orchestration action category such as retry, pause, resume, or escalate."
      t.string :status,
        null: false,
        comment: "Decision outcome status: applied, noop, or failed."
      t.integer :sequence,
        null: false,
        comment: "Per-action sequence number so repeated retries remain distinguishable."
      t.jsonb :signals,
        null: false,
        default: {},
        comment: "Normalized triggering signals and counters that informed the decision."
      t.jsonb :result,
        null: false,
        default: {},
        comment: "Persisted outcome details for the selected decision."

      t.timestamps
    end

    add_index :orchestration_decision_events, [ :project_id, :created_at ],
      name: "idx_orchestration_decision_events_project_time"
    add_index :orchestration_decision_events, [ :project_id, :action, :status, :created_at ],
      name: "idx_orch_decision_events_project_action_status"
    add_index :orchestration_decision_events, [ :issue_id, :action, :sequence ],
      name: "idx_orch_decision_events_issue_action_sequence"
    add_index :orchestration_decision_events, [ :agent_run_id, :action, :sequence ],
      name: "idx_orch_decision_events_run_action_sequence"

    reversible do |dir|
      dir.up do
        execute <<~SQL
          ALTER TABLE orchestration_decision_events ENABLE ROW LEVEL SECURITY;
          CREATE POLICY tenant_isolation ON orchestration_decision_events
            USING  (paid_tenant_bypass() OR EXISTS (
              SELECT 1 FROM projects
              WHERE projects.id = orchestration_decision_events.project_id
                AND projects.account_id = paid_current_account_id()))
            WITH CHECK (paid_tenant_bypass() OR EXISTS (
              SELECT 1 FROM projects
              WHERE projects.id = orchestration_decision_events.project_id
                AND projects.account_id = paid_current_account_id()));
        SQL
      end
      dir.down do
        execute <<~SQL
          DROP POLICY IF EXISTS tenant_isolation ON orchestration_decision_events;
          ALTER TABLE orchestration_decision_events DISABLE ROW LEVEL SECURITY;
        SQL
      end
    end
  end
end
