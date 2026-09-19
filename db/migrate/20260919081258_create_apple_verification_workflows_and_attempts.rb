# frozen_string_literal: true

class CreateAppleVerificationWorkflowsAndAttempts < ActiveRecord::Migration[8.1]
  def up
    add_column :projects, :apple_verification_settings, :jsonb, default: {}, null: false, comment: "Apple verification mode and inferred repository profiles (RDR-068)."
    create_table :apple_verification_workflow_revisions, comment: "Committed Apple verification workflow revisions and digest-bound approvals." do |t|
      t.references :project, null: false, foreign_key: true
      t.references :approved_by, foreign_key: { to_table: :users }
      t.string :profile_name, null: false
      t.string :state, null: false, default: "draft"
      t.string :source_digest, null: false
      t.jsonb :referenced_files, null: false, default: []
      t.jsonb :worker_constraints, null: false, default: {}
      t.jsonb :checks, null: false, default: {}
      t.string :lifecycle_gate
      t.datetime :approved_at
      t.timestamps
    end
    add_index :apple_verification_workflow_revisions, [ :project_id, :profile_name, :created_at ], name: "index_apple_workflows_on_project_profile_created"
    create_table :apple_verification_attempts, comment: "Apple verification queue, execution, and outcome state." do |t|
      t.references :project, null: false, foreign_key: true
      t.references :workflow_revision, null: false, foreign_key: { to_table: :apple_verification_workflow_revisions }
      t.references :retry_of, foreign_key: { to_table: :apple_verification_attempts }
      t.references :waived_by, foreign_key: { to_table: :users }
      t.string :state, null: false, default: "queued"
      t.integer :queue_position
      t.string :failure_class
      t.jsonb :result, null: false, default: {}
      t.jsonb :provenance, null: false, default: {}
      t.string :temporal_workflow_id, comment: "Durable worker workflow owning this attempt."
      t.jsonb :worker_handle, null: false, default: {}, comment: "Opaque provider handle used for worker lifecycle control."
      t.text :waiver_reason
      t.datetime :cancelled_at
      t.datetime :retained_vm_destroyed_at
      t.timestamps
    end
    add_index :apple_verification_attempts, [ :project_id, :state, :created_at ], name: "index_apple_attempts_on_project_state_created"
    create_table :apple_verification_artifacts, comment: "Private Apple verification artifacts with protected storage references." do |t|
      t.references :attempt, null: false, foreign_key: { to_table: :apple_verification_attempts }
      t.string :kind, null: false
      t.string :storage_key, null: false
      t.string :content_type
      t.jsonb :metadata, null: false, default: {}
      t.datetime :expires_at
      t.timestamps
    end
    add_index :apple_verification_artifacts, [ :attempt_id, :kind ]
    enable_tenant_row_level_security
  end

  def down
    disable_tenant_row_level_security
    drop_table :apple_verification_artifacts
    drop_table :apple_verification_attempts
    drop_table :apple_verification_workflow_revisions
    remove_column :projects, :apple_verification_settings
  end

  private

  def enable_tenant_row_level_security
    safety_assured do
      execute project_policy_sql("apple_verification_workflow_revisions", "project_id")
      execute project_policy_sql("apple_verification_attempts", "project_id")
      execute attempt_policy_sql
    end
  end

  def disable_tenant_row_level_security
    safety_assured do
      %w[apple_verification_artifacts apple_verification_attempts apple_verification_workflow_revisions].each do |table|
        execute "DROP POLICY IF EXISTS tenant_isolation ON #{table}"
        execute "ALTER TABLE #{table} NO FORCE ROW LEVEL SECURITY"
        execute "ALTER TABLE #{table} DISABLE ROW LEVEL SECURITY"
      end
    end
  end

  def project_policy_sql(table, project_id)
    <<~SQL
      ALTER TABLE #{table} ENABLE ROW LEVEL SECURITY;
      ALTER TABLE #{table} FORCE ROW LEVEL SECURITY;
      CREATE POLICY tenant_isolation ON #{table}
        AS PERMISSIVE FOR ALL
        USING (paid_tenant_bypass() OR EXISTS (
          SELECT 1 FROM projects WHERE projects.id = #{table}.#{project_id}
            AND projects.account_id = paid_current_account_id()
        ))
        WITH CHECK (paid_tenant_bypass() OR EXISTS (
          SELECT 1 FROM projects WHERE projects.id = #{table}.#{project_id}
            AND projects.account_id = paid_current_account_id()
        ));
    SQL
  end

  def attempt_policy_sql
    <<~SQL
      ALTER TABLE apple_verification_artifacts ENABLE ROW LEVEL SECURITY;
      ALTER TABLE apple_verification_artifacts FORCE ROW LEVEL SECURITY;
      CREATE POLICY tenant_isolation ON apple_verification_artifacts
        AS PERMISSIVE FOR ALL
        USING (paid_tenant_bypass() OR EXISTS (
          SELECT 1 FROM apple_verification_attempts
          INNER JOIN projects ON projects.id = apple_verification_attempts.project_id
          WHERE apple_verification_attempts.id = apple_verification_artifacts.attempt_id
            AND projects.account_id = paid_current_account_id()
        ))
        WITH CHECK (paid_tenant_bypass() OR EXISTS (
          SELECT 1 FROM apple_verification_attempts
          INNER JOIN projects ON projects.id = apple_verification_attempts.project_id
          WHERE apple_verification_attempts.id = apple_verification_artifacts.attempt_id
            AND projects.account_id = paid_current_account_id()
        ));
    SQL
  end
end
