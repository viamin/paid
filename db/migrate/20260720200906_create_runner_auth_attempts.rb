# frozen_string_literal: true

class CreateRunnerAuthAttempts < ActiveRecord::Migration[8.1]
  def up
    create_table :runner_auth_attempts,
      comment: "Structured telemetry for runner subscription-auth attempts, used to compare " \
        "managed RunnerCredential auth with legacy host-mounted local auth before remote cutover " \
        "(RDR-041 / #2960)." do |t|
      t.references :account, null: false, foreign_key: true,
        comment: "Owning account; denormalized for account-scoped analytics and reporting."
      t.references :project, null: false, foreign_key: { on_delete: :cascade },
        comment: "Owning project; mirrors the agent_run linkage for tenant-isolated reporting."
      t.references :agent_run, null: true, foreign_key: { on_delete: :nullify },
        comment: "Agent run that triggered this attempt, when the attempt is bound to a run."
      t.references :runner_credential, null: true, foreign_key: { on_delete: :nullify },
        comment: "RunnerCredential record the attempt used, when the attempt is managed."

      t.string :runner_key, null: false, limit: 64,
        comment: "Provider key (claude, codex, gemini, copilot)."
      t.string :attempt_stage, null: false, limit: 32,
        comment: "Lifecycle stage of the attempt: materialization, refresh, lease, harvest, eligibility."
      t.string :auth_source, null: false, limit: 32,
        comment: "Resolved auth source: managed, host_forwarded, api_key_proxy, none."
      t.string :materialization_mode, null: true, limit: 32,
        comment: "Materializer mode: env, native_file, broker, host_mount, unsupported."
      t.string :container_host, null: true, limit: 64,
        comment: "Container backend identifier that the attempt was bound to."
      t.boolean :backend_supports_host_paths, null: true,
        comment: "Whether the resolved backend supports host bind mounts at attempt time."
      t.boolean :backend_remote, null: true,
        comment: "Whether the resolved backend was remote at attempt time."

      t.string :feature_flag_state, null: true, limit: 32,
        comment: "State of the managed_subscription_runner_auth flag: enabled, disabled, unregistered."
      t.string :refresh_state, null: true, limit: 32,
        comment: "Refresh outcome: not_needed, refreshed, refresh_failed, expired, not_applicable."
      t.string :lease_state, null: true, limit: 32,
        comment: "Lease outcome: none, acquired, waited, timeout, not_applicable."
      t.string :result, null: false, limit: 32,
        comment: "Final attempt outcome: materialized, skipped, failed, harvested, harvest_failed, " \
          "refreshed, refresh_failed, expired, lease_acquired, lease_timeout."
      t.string :failure_reason, null: true, limit: 64,
        comment: "UI-safe failure reason code (e.g. credential_expired, refresh_token_reused)."

      t.integer :duration_ms, null: true,
        comment: "Wall-clock duration of the attempt in milliseconds, when measurable."
      t.integer :retry_count, null: false, default: 0,
        comment: "Number of retries performed before recording this attempt outcome."

      t.datetime :attempted_at, null: false,
        comment: "When the attempt occurred; mirrors created_at but is set explicitly so background " \
          "recorders can write back-dated rows when telemetry is flushed after the real attempt."
      t.jsonb :metadata, null: false, default: {},
        comment: "Non-secret contextual fields such as feature-flag rollout and materializer rotation risk."

      t.timestamps
    end

    add_index :runner_auth_attempts,
      [ :account_id, :attempted_at ],
      name: "idx_runner_auth_attempts_account_attempted"
    add_index :runner_auth_attempts,
      [ :project_id, :attempted_at ],
      name: "idx_runner_auth_attempts_project_attempted"
    add_index :runner_auth_attempts,
      [ :agent_run_id, :attempt_stage, :attempted_at ],
      name: "idx_runner_auth_attempts_run_stage_attempted"
    # strong_migrations warns on >3 column indexes; this one is intentional
    # because analytics queries (Analytics::RunnerAuthAttempts::BaseQuery)
    # frequently filter on all four columns together when slicing managed-vs-
    # host comparisons by provider and Docker host over time.
    safety_assured do
      add_index :runner_auth_attempts,
        [ :runner_key, :auth_source, :container_host, :attempted_at ],
        name: "idx_runner_auth_attempts_provider_source_host_attempted"
    end
    add_index :runner_auth_attempts,
      [ :result, :attempted_at ],
      name: "idx_runner_auth_attempts_result_attempted"
    add_index :runner_auth_attempts,
      [ :attempt_stage, :result, :attempted_at ],
      name: "idx_runner_auth_attempts_stage_result_attempted"

    # RLS is the documented exception to the Rails-helper rule (AGENTS.md):
    # PostgreSQL row-level security and CREATE POLICY have no equivalent
    # helper, so the SQL stays minimal and isolated to this block.
    safety_assured do
      execute <<~SQL
        ALTER TABLE runner_auth_attempts ENABLE ROW LEVEL SECURITY;
        ALTER TABLE runner_auth_attempts FORCE ROW LEVEL SECURITY;
        CREATE POLICY tenant_isolation ON runner_auth_attempts
          USING (
            paid_tenant_bypass() OR EXISTS (
              SELECT 1 FROM projects
              WHERE projects.id = runner_auth_attempts.project_id
                AND projects.account_id = paid_current_account_id()
            )
          )
          WITH CHECK (
            paid_tenant_bypass() OR EXISTS (
              SELECT 1 FROM projects
              WHERE projects.id = runner_auth_attempts.project_id
                AND projects.account_id = paid_current_account_id()
            )
          );
      SQL
    end
  end

  def down
    safety_assured do
      execute "DROP POLICY IF EXISTS tenant_isolation ON runner_auth_attempts"
      execute "ALTER TABLE runner_auth_attempts NO FORCE ROW LEVEL SECURITY"
      execute "ALTER TABLE runner_auth_attempts DISABLE ROW LEVEL SECURITY"
    end

    drop_table :runner_auth_attempts
  end
end
