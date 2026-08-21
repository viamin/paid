# frozen_string_literal: true

# @spec RESOURCE-LEDGER-007
class CreateExecutionResourceLedgerEntries < ActiveRecord::Migration[8.1]
  def up
    create_table :execution_resource_ledger_entries, comment: "Durable ledger of externally provisioned execution resources (containers, sidecars, workspaces, networks, tunnels, temporary storage) tracked across their provisioning-to-cleanup lifecycle." do |t|
      t.references :account, null: false, foreign_key: { on_delete: :cascade }, index: false
      # project/agent_run use on_delete: :nullify (not :cascade) because this
      # table's purpose is to durably track external resources so orphaned or
      # leaked resources can be reconciled independent of the process that
      # created them; the column stays nullable so the FK action can clear it
      # without violating a NOT NULL constraint, while the model still
      # requires project at creation time (see ExecutionResourceLedgerEntry).
      t.references :project, null: true, foreign_key: { on_delete: :nullify }
      t.references :agent_run, null: true, foreign_key: { on_delete: :nullify }
      t.integer :run_attempt, comment: "Attempt number of the agent run that requested this resource, when applicable."
      t.string :runner_type, limit: 64, null: false, comment: "Execution runner that owns this resource, e.g. docker, kubernetes."
      t.string :backend, limit: 64, comment: "Backend or provider identifier for the runner, e.g. local, ecs, gke."
      t.string :resource_kind, limit: 32, null: false, comment: "Category of resource: primary_environment, service, sidecar, workspace, network, preview_tunnel, temporary_storage."
      t.string :provider_resource_id, limit: 255, comment: "Provider-assigned identifier for the resource (container ID, volume ID, tunnel ID, etc.)."
      t.jsonb :tags, null: false, default: {}, comment: "Non-secret ownership/labeling tags attached to the resource. Never stores secret values."
      t.string :status, limit: 32, null: false, default: "provisioning", comment: "Lifecycle status: provisioning, active, cleanup_pending, deleted, orphaned, cleanup_failed."
      t.integer :cleanup_attempts, null: false, default: 0, comment: "Number of cleanup attempts made for this resource."
      t.datetime :cleanup_last_attempted_at, comment: "Timestamp of the most recent cleanup attempt."
      t.text :cleanup_last_error, comment: "Error message from the most recent failed cleanup attempt."
      t.jsonb :runner_handle, null: false, default: {}, comment: "Serialized ExecutionRunners::RunnerHandle reference used to locate the resource for cleanup/reconciliation."
      t.datetime :activated_at, comment: "When the resource transitioned to active."
      t.datetime :cleanup_requested_at, comment: "When cleanup was first requested for the resource."
      t.datetime :deleted_at, comment: "When the resource was confirmed deleted."
      t.datetime :orphaned_at, comment: "When the resource was flagged as orphaned."
      t.datetime :cleanup_failed_at, comment: "When the most recent cleanup attempt failed."

      t.timestamps null: false
    end

    add_index :execution_resource_ledger_entries, [ :account_id, :created_at ], order: { created_at: :desc }, name: "idx_execution_resource_ledger_account_recent"
    add_index :execution_resource_ledger_entries, [ :resource_kind ], name: "index_execution_resource_ledger_entries_on_resource_kind"
    add_index :execution_resource_ledger_entries, [ :status ], name: "index_execution_resource_ledger_entries_on_status"
    add_index :execution_resource_ledger_entries, [ :runner_type, :backend, :provider_resource_id ],
      unique: true,
      where: "provider_resource_id IS NOT NULL",
      name: "idx_execution_resource_ledger_provider_identity"

    add_check_constraint :execution_resource_ledger_entries,
      "resource_kind IN ('primary_environment', 'service', 'sidecar', 'workspace', 'network', 'preview_tunnel', 'temporary_storage')",
      name: "chk_execution_resource_ledger_kind_valid"
    add_check_constraint :execution_resource_ledger_entries,
      "status IN ('provisioning', 'active', 'cleanup_pending', 'deleted', 'orphaned', 'cleanup_failed')",
      name: "chk_execution_resource_ledger_status_valid"
    add_check_constraint :execution_resource_ledger_entries,
      "cleanup_attempts >= 0",
      name: "chk_execution_resource_ledger_cleanup_attempts_nonneg"

    safety_assured do
      execute <<~SQL
        ALTER TABLE execution_resource_ledger_entries ENABLE ROW LEVEL SECURITY;
        ALTER TABLE execution_resource_ledger_entries FORCE ROW LEVEL SECURITY;
        CREATE POLICY tenant_isolation ON execution_resource_ledger_entries
          AS PERMISSIVE FOR ALL
          USING (paid_tenant_bypass() OR (execution_resource_ledger_entries.account_id = paid_current_account_id()))
          WITH CHECK (paid_tenant_bypass() OR (execution_resource_ledger_entries.account_id = paid_current_account_id()));
      SQL
    end
  end

  def down
    safety_assured { execute "DROP POLICY IF EXISTS tenant_isolation ON execution_resource_ledger_entries" }
    safety_assured { execute "ALTER TABLE execution_resource_ledger_entries NO FORCE ROW LEVEL SECURITY" }
    safety_assured { execute "ALTER TABLE execution_resource_ledger_entries DISABLE ROW LEVEL SECURITY" }

    drop_table :execution_resource_ledger_entries
  end
end
