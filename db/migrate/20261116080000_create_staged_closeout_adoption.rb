# frozen_string_literal: true

class CreateStagedCloseoutAdoption < ActiveRecord::Migration[8.1]
  def up
    create_table :staged_closeout_enrollments do |t|
      t.references :account, null: false, foreign_key: true
      t.references :project, null: false, foreign_key: true, index: { unique: true }
      t.boolean :enabled, null: false, default: false
      t.references :reviewed_by, foreign_key: { to_table: :users }
      t.datetime :reviewed_at
      t.integer :revision, null: false, default: 1
      t.timestamps
    end

    create_table :staged_closeout_mappings do |t|
      t.references :account, null: false, foreign_key: true
      t.references :project, null: false, foreign_key: true
      t.references :issue, null: false, foreign_key: true
      t.references :staged_closeout_enrollment, null: false, foreign_key: true, index: { name: "index_staged_closeout_mappings_on_enrollment" }
      t.references :reviewed_by, null: false, foreign_key: { to_table: :users }
      t.string :criterion_key, null: false
      t.string :criterion_digest, null: false
      t.string :stage, null: false
      t.string :phase, null: false
      t.string :target_shape, null: false
      t.string :execution_path, null: false
      t.string :target_key, null: false
      t.string :target_version, null: false
      t.string :target_digest, null: false
      t.string :environment_class
      t.integer :freshness_seconds, null: false
      t.jsonb :retry_policy, null: false, default: {}
      t.string :status, null: false, default: "approved"
      t.integer :revision, null: false
      t.datetime :reviewed_at, null: false
      t.datetime :invalidated_at
      t.string :invalidation_reason
      t.timestamps
    end
    add_index :staged_closeout_mappings, [ :issue_id, :criterion_key, :revision ], unique: true, name: "index_staged_closeout_mapping_revisions"
    add_index :staged_closeout_mappings, [ :project_id, :status ]
    enable_tenant_rls
  end

  def down
    disable_tenant_rls
    drop_table :staged_closeout_mappings
    drop_table :staged_closeout_enrollments
  end

  private

  def enable_tenant_rls
    %w[staged_closeout_enrollments staged_closeout_mappings].each do |table|
      safety_assured do
        execute "ALTER TABLE #{table} ENABLE ROW LEVEL SECURITY"
        execute "ALTER TABLE #{table} FORCE ROW LEVEL SECURITY"
        execute "CREATE POLICY tenant_isolation ON #{table} AS PERMISSIVE FOR ALL USING (paid_tenant_bypass() OR (#{table}.account_id = paid_current_account_id())) WITH CHECK (paid_tenant_bypass() OR (#{table}.account_id = paid_current_account_id()))"
      end
    end
  end

  def disable_tenant_rls
    %w[staged_closeout_mappings staged_closeout_enrollments].each do |table|
      safety_assured do
        execute "DROP POLICY IF EXISTS tenant_isolation ON #{table}"
        execute "ALTER TABLE #{table} NO FORCE ROW LEVEL SECURITY"
        execute "ALTER TABLE #{table} DISABLE ROW LEVEL SECURITY"
      end
    end
  end
end
