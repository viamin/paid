# frozen_string_literal: true

# @spec PROJECT-DELEGATION-007
class CreateProjectDelegationPilotMetrics < ActiveRecord::Migration[8.1]
  def up
    create_table :project_delegation_pilot_metrics do |t|
      t.references :account, null: false, foreign_key: true
      t.references :project, null: false, foreign_key: true
      t.string :posture, null: false, default: "conservative"
      t.datetime :window_started_at, null: false
      t.datetime :window_ended_at, null: false
      t.integer :completed_issues, null: false, default: 0
      t.integer :total_issues, null: false, default: 0
      t.integer :inbox_decisions, null: false, default: 0
      t.float :median_decision_seconds
      t.float :p90_decision_seconds
      t.decimal :completion_rate, precision: 6, scale: 5
      t.integer :reversed_decisions, null: false, default: 0
      t.decimal :reversal_rate, precision: 6, scale: 5
      t.jsonb :revisions, null: false, default: {}
      t.jsonb :reversals, null: false, default: []
      t.jsonb :exclusions, null: false, default: {}
      t.jsonb :evidence, null: false, default: {}
      t.timestamps
    end

    add_index :project_delegation_pilot_metrics, [ :project_id, :posture, :window_started_at ],
      name: "index_pilot_metrics_on_project_posture_window", unique: true

    enable_tenant_rls
  end

  def down
    disable_tenant_rls
    drop_table :project_delegation_pilot_metrics
  end

  def enable_tenant_rls
    safety_assured do
      execute "ALTER TABLE project_delegation_pilot_metrics ENABLE ROW LEVEL SECURITY"
      execute "ALTER TABLE project_delegation_pilot_metrics FORCE ROW LEVEL SECURITY"
      execute "DROP POLICY IF EXISTS tenant_isolation ON project_delegation_pilot_metrics"
      execute <<~SQL
        CREATE POLICY tenant_isolation ON project_delegation_pilot_metrics
        AS PERMISSIVE
        FOR ALL
        USING (paid_tenant_bypass() OR (#{tenant_condition}))
        WITH CHECK (paid_tenant_bypass() OR (#{tenant_condition}))
      SQL
    end
  end

  def disable_tenant_rls
    safety_assured do
      execute "DROP POLICY IF EXISTS tenant_isolation ON project_delegation_pilot_metrics"
      execute "ALTER TABLE project_delegation_pilot_metrics NO FORCE ROW LEVEL SECURITY"
      execute "ALTER TABLE project_delegation_pilot_metrics DISABLE ROW LEVEL SECURITY"
    end
  end

  private

  def tenant_condition
    <<~SQL.squish
      project_delegation_pilot_metrics.account_id = paid_current_account_id()
      AND EXISTS (
        SELECT 1 FROM projects
        WHERE projects.id = project_delegation_pilot_metrics.project_id
          AND projects.account_id = paid_current_account_id()
      )
    SQL
  end
end
