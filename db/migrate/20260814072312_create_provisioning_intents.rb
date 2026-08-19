# frozen_string_literal: true

# Execution-resource provisioning-intent ledger for RDR-058. Each row records a
# runner's intent to create an execution resource (container, workspace volume,
# …) BEFORE the provider create call is issued, so a crash between provider
# creation and runner-handle persistence leaves enough information to
# reconcile the orphaned resource back to its Paid origin.
#
# The ledger is append-only across the provision lifecycle (pending → created →
# linked); cleanup does not delete rows, preserving the provision history for
# auditing. Ownership tags mirror the `paid.*` labels burned into the live
# provider resource so a reconciliation scan can locate orphans by ledger row or
# by tag.
class CreateProvisioningIntents < ActiveRecord::Migration[8.1]
  def up
    return if table_exists?(:provisioning_intents)

    create_table :provisioning_intents,
      comment: "Execution-resource provisioning-intent ledger rows recording runner intent before provider create calls so orphaned resources remain reconcileable (RDR-058)." do |t|
        t.references :account, null: false, foreign_key: true,
          comment: "Owning account (ownership tag 'account')."
        t.references :project, null: true, foreign_key: true,
          comment: "Owning project (ownership tag 'project')."
        t.references :agent_run, null: true, foreign_key: true,
          comment: "Agent run the resource was provisioned for (ownership tag 'run')."

        t.string :resource_kind, null: false, limit: 100,
          comment: "Kind of execution resource the runner intends to create (e.g. 'container', 'workspace_volume')."
        t.string :runner_type, null: false, limit: 50,
          comment: "Runner type that recorded the intent (matches RunnerHandle#runner_type, e.g. 'local_docker')."
        t.string :environment, null: false, limit: 100,
          comment: "Paid deployment environment the resource belongs to (ownership tag 'environment')."
        t.integer :attempt, null: false, default: 0,
          comment: "Provision attempt ordinal for this run/resource kind (ownership tag 'attempt')."
        t.string :provider_resource_id, limit: 200,
          comment: "Provider resource identifier captured once the create call succeeds (e.g. Docker container id)."
        t.string :provider_resource_host, limit: 200,
          comment: "Backend host owning the provider resource (e.g. container_host)."
        t.jsonb :runner_handle,
          comment: "Serialized ExecutionRunners::RunnerHandle linked once the runner builds the handle."
        t.jsonb :ownership_tags, null: false, default: {},
          comment: "Stable Paid ownership tag map (paid.* labels) applied to the live resource for reconciliation."
        t.boolean :tagging_supported, null: false, default: true,
          comment: "Whether the runner/provider could apply ownership tags; false records an explicit degradation."
        t.string :status, null: false, default: "pending", limit: 50,
          comment: "Ledger lifecycle state: pending | created | linked | failed."
        t.datetime :reconciled_at,
          comment: "When a reconciliation process resolved this ledger row (e.g. reclaimed an orphan)."
        t.jsonb :metadata, null: false, default: {},
          comment: "Additional structured context (degradation reasons, reconciliation notes)."

        t.timestamps
      end

    add_index :provisioning_intents, :provider_resource_id,
      where: "provider_resource_id IS NOT NULL",
      name: "index_provisioning_intents_on_provider_resource_id",
      if_not_exists: true
    add_index :provisioning_intents, [ :status, :created_at ],
      name: "index_provisioning_intents_on_status_and_created_at",
      if_not_exists: true
    # unique: a runner records the intent BEFORE the provider create call, so
    # this is the concurrency guard for the attempt ordinal. next_attempt_for
    # (count) then record_intent (create!) is not atomic — two writers can both
    # observe the same count under concurrent retries. The unique index makes
    # the second writer fail loudly (RecordNotUnique) instead of silently
    # persisting a duplicate ownership-tag attempt that reconciliation can't
    # disambiguate.
    add_index :provisioning_intents, [ :agent_run_id, :resource_kind, :attempt ],
      unique: true,
      name: "index_provisioning_intents_on_run_kind_attempt",
      if_not_exists: true

    # RLS is the documented exception to the Rails-helper rule (AGENTS.md):
    # PostgreSQL row-level security and CREATE POLICY have no equivalent
    # helper, so the SQL stays minimal and isolated to this block. The ledger
    # is account-owned with optional project/run references, mirroring the
    # direct-account tenant tables in EnableTenantRowLevelSecurity.
    safety_assured do
      execute <<~SQL
        ALTER TABLE provisioning_intents ENABLE ROW LEVEL SECURITY;
        ALTER TABLE provisioning_intents FORCE ROW LEVEL SECURITY;
        CREATE POLICY tenant_isolation ON provisioning_intents
          AS PERMISSIVE FOR ALL
          USING (
            paid_tenant_bypass() OR (
              provisioning_intents.account_id = paid_current_account_id()
              AND (
                provisioning_intents.project_id IS NULL
                OR EXISTS (
                  SELECT 1 FROM projects
                  WHERE projects.id = provisioning_intents.project_id
                    AND projects.account_id = paid_current_account_id()
                )
              )
              AND (
                provisioning_intents.agent_run_id IS NULL
                OR EXISTS (
                  SELECT 1 FROM agent_runs
                  INNER JOIN projects ON projects.id = agent_runs.project_id
                  WHERE agent_runs.id = provisioning_intents.agent_run_id
                    AND projects.account_id = paid_current_account_id()
                )
              )
            )
          )
          WITH CHECK (
            paid_tenant_bypass() OR (
              provisioning_intents.account_id = paid_current_account_id()
              AND (
                provisioning_intents.project_id IS NULL
                OR EXISTS (
                  SELECT 1 FROM projects
                  WHERE projects.id = provisioning_intents.project_id
                    AND projects.account_id = paid_current_account_id()
                )
              )
              AND (
                provisioning_intents.agent_run_id IS NULL
                OR EXISTS (
                  SELECT 1 FROM agent_runs
                  INNER JOIN projects ON projects.id = agent_runs.project_id
                  WHERE agent_runs.id = provisioning_intents.agent_run_id
                    AND projects.account_id = paid_current_account_id()
                )
              )
            )
          );
      SQL
    end
  end

  def down
    return unless table_exists?(:provisioning_intents)

    safety_assured do
      execute "DROP POLICY IF EXISTS tenant_isolation ON provisioning_intents"
      execute "ALTER TABLE provisioning_intents NO FORCE ROW LEVEL SECURITY"
      execute "ALTER TABLE provisioning_intents DISABLE ROW LEVEL SECURITY"
    end

    drop_table :provisioning_intents, if_exists: true
  end
end
