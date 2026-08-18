# frozen_string_literal: true

# RDR-061 — append-only execution audit event stream, distinct from
# operational logs (AgentRunLog) and telemetry (RunnerAuthAttempt,
# container_metrics). Captures execution infrastructure/security events
# (credential resolution, network policy application, resource
# provisioning) with secret-free metadata so the audit trail can be
# retained and queried independently of debug-level operational data.
class CreateExecutionAuditEvents < ActiveRecord::Migration[8.1]
  def up
    create_table :execution_audit_events,
      comment: "Append-only execution infrastructure/security audit trail (RDR-061). " \
        "Rows are never updated after insert; secret-shaped metadata is rejected at the model layer." do |t|
      t.references :account, null: false, foreign_key: true,
        comment: "Owning account; the tenant scope for row-level security."
      t.references :project, null: true, foreign_key: { on_delete: :nullify },
        comment: "Owning project, when the event is project-scoped."
      t.references :agent_run, null: true, foreign_key: { on_delete: :nullify },
        comment: "Agent run the event concerns, when the event is run-scoped."
      t.integer :run_attempt, null: true,
        comment: "Attempt/iteration number of the agent run when the event occurred, when applicable."

      t.string :event_name, null: false, limit: 100,
        comment: "Namespaced execution/security event name, e.g. container.provisioned, credential.materialized."
      t.integer :event_version, null: false, default: 1,
        comment: "Schema version of this event's payload shape."
      t.datetime :occurred_at, null: false,
        comment: "When the underlying event happened; may predate created_at for buffered telemetry."

      t.string :actor_type, limit: 50,
        comment: "Actor category: user, system, agent, job, runner."
      t.string :actor_id, limit: 100,
        comment: "Actor identifier within actor_type; free text so system actors don't need a users row."

      t.string :runner_key, limit: 64,
        comment: "Provider/runner key (claude, codex, gemini, copilot), when the event is runner-specific."
      t.string :backend, limit: 64,
        comment: "Container backend identifier that executed or was targeted by the event."

      t.string :image_reference, limit: 255,
        comment: "Container image reference (repository:tag) used for the run, when applicable."
      t.string :image_digest, limit: 128,
        comment: "Content-addressable image digest (e.g. sha256:...), when resolvable."

      t.jsonb :credential_classes, null: false, default: [],
        comment: "Non-secret credential source classes involved (proxy_restricted, subscription_auth, " \
          "direct_outbound), never raw credential values."
      t.jsonb :network_policy, null: false, default: {},
        comment: "Secret-free network policy snapshot (mode, firewall, allow_destinations) applied at event time."

      t.string :resource_type, limit: 50,
        comment: "Type of the primary resource this event concerns (container, workspace_volume, " \
          "service_container, network)."
      t.string :resource_id, limit: 255,
        comment: "Identifier of the primary resource this event concerns."

      t.string :correlation_id, limit: 255,
        comment: "Cross-system correlation id (e.g. Temporal workflow id) for tracing an event across subsystems."

      t.jsonb :metadata, null: false, default: {},
        comment: "Additional secret-free event context; rejected at the model layer if it contains " \
          "secret-shaped keys or values."

      t.datetime :created_at, null: false
    end

    add_index :execution_audit_events, [ :account_id, :created_at ],
      name: "idx_execution_audit_events_account_created"
    add_index :execution_audit_events, :event_name,
      name: "idx_execution_audit_events_event_name"
    add_index :execution_audit_events, :runner_key,
      name: "idx_execution_audit_events_runner_key"
    add_index :execution_audit_events, :image_reference,
      name: "idx_execution_audit_events_image_reference"
    add_index :execution_audit_events, [ :resource_type, :resource_id ],
      name: "idx_execution_audit_events_resource"
    add_index :execution_audit_events, :correlation_id,
      name: "idx_execution_audit_events_correlation_id"
    add_index :execution_audit_events, :created_at,
      using: :brin, name: "idx_execution_audit_events_created_at_brin"

    # RLS is the documented exception to the Rails-helper rule (AGENTS.md):
    # PostgreSQL row-level security and CREATE POLICY have no equivalent
    # helper, so the SQL stays minimal and isolated to this block.
    safety_assured do
      execute <<~SQL
        ALTER TABLE execution_audit_events ENABLE ROW LEVEL SECURITY;
        ALTER TABLE execution_audit_events FORCE ROW LEVEL SECURITY;
        CREATE POLICY tenant_isolation ON execution_audit_events
          USING (paid_tenant_bypass() OR account_id = paid_current_account_id())
          WITH CHECK (paid_tenant_bypass() OR account_id = paid_current_account_id());
      SQL
    end
  end

  def down
    safety_assured do
      execute "DROP POLICY IF EXISTS tenant_isolation ON execution_audit_events"
      execute "ALTER TABLE execution_audit_events NO FORCE ROW LEVEL SECURITY"
      execute "ALTER TABLE execution_audit_events DISABLE ROW LEVEL SECURITY"
    end

    drop_table :execution_audit_events
  end
end
