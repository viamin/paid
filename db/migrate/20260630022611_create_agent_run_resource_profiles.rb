# frozen_string_literal: true

class CreateAgentRunResourceProfiles < ActiveRecord::Migration[8.1]
  def change
    create_table :agent_run_resource_profiles,
      comment: "Learned memory usage rollups for agent runs across exact and fallback scopes." do |t|
      t.references :account, foreign_key: { on_delete: :cascade },
        comment: "Owning account for account/project-scoped profiles."
      t.references :project, foreign_key: { on_delete: :cascade },
        comment: "Project for exact or project-level profiles."
      t.string :profile_level, null: false, comment: "Profile scope: specific, runner_goal, project, account, or global."
      t.string :lookup_key, null: false, comment: "Deterministic unique key for one profile scope row."
      t.string :runner_key, comment: "Normalized runner key for runner-scoped profiles."
      t.string :goal, comment: "Agent goal for runner-scoped profiles."
      t.bigint :p50_memory_bytes, null: false, default: 0, comment: "Median observed peak memory across sampled runs."
      t.bigint :p95_memory_bytes, null: false, default: 0, comment: "95th percentile observed peak memory across sampled runs."
      t.bigint :max_memory_bytes, null: false, default: 0, comment: "Maximum observed peak memory across sampled runs."
      t.integer :sample_count, null: false, default: 0, comment: "Number of terminal runs contributing a memory sample."
      t.integer :oom_count, null: false, default: 0, comment: "Number of sampled runs that showed container OOM evidence."
      t.datetime :last_oom_at, comment: "Timestamp of the most recent sampled OOM event."
      t.bigint :recommended_memory_limit_bytes, null: false, default: 0,
        comment: "Learned memory limit recommendation derived from observed peaks and OOMs."
      t.timestamps
    end

    add_index :agent_run_resource_profiles, :lookup_key, unique: true
    add_index :agent_run_resource_profiles, [ :profile_level, :sample_count ]
    add_index :agent_run_resource_profiles, [ :runner_key, :goal ], where: "runner_key IS NOT NULL AND goal IS NOT NULL"

    reversible do |dir|
      dir.up do
        safety_assured do
          execute <<~SQL
            ALTER TABLE agent_run_resource_profiles ENABLE ROW LEVEL SECURITY;
            ALTER TABLE agent_run_resource_profiles FORCE ROW LEVEL SECURITY;
            CREATE POLICY tenant_isolation ON agent_run_resource_profiles
              USING (
                paid_tenant_bypass() OR (
                  agent_run_resource_profiles.account_id IS NULL
                  OR agent_run_resource_profiles.account_id = paid_current_account_id()
                )
              )
              WITH CHECK (
                paid_tenant_bypass() OR (
                  agent_run_resource_profiles.account_id IS NULL
                  OR agent_run_resource_profiles.account_id = paid_current_account_id()
                )
              );
          SQL
        end
      end

      dir.down do
        safety_assured do
          execute "DROP POLICY IF EXISTS tenant_isolation ON agent_run_resource_profiles"
          execute "ALTER TABLE agent_run_resource_profiles NO FORCE ROW LEVEL SECURITY"
          execute "ALTER TABLE agent_run_resource_profiles DISABLE ROW LEVEL SECURITY"
        end
      end
    end
  end
end
