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

  def enable_tenant_rls
    tenant_conditions.each do |table, condition|
      safety_assured do
        execute "ALTER TABLE #{table} ENABLE ROW LEVEL SECURITY"
        execute "ALTER TABLE #{table} FORCE ROW LEVEL SECURITY"
        execute <<~SQL
          CREATE POLICY tenant_isolation ON #{table}
            AS PERMISSIVE FOR ALL
            USING (paid_tenant_bypass() OR (#{condition}))
            WITH CHECK (paid_tenant_bypass() OR (#{condition}))
        SQL
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

  private

  def tenant_conditions
    {
      "staged_closeout_enrollments" => enrollment_tenant_condition,
      "staged_closeout_mappings" => mapping_tenant_condition
    }
  end

  def enrollment_tenant_condition
    <<~SQL.squish
      staged_closeout_enrollments.account_id = paid_current_account_id()
      AND EXISTS (
        SELECT 1 FROM projects
        WHERE projects.id = staged_closeout_enrollments.project_id
          AND projects.account_id = paid_current_account_id()
      )
      AND (
        staged_closeout_enrollments.reviewed_by_id IS NULL
        OR EXISTS (
          SELECT 1 FROM users
          WHERE users.id = staged_closeout_enrollments.reviewed_by_id
            AND users.account_id = paid_current_account_id()
        )
      )
    SQL
  end

  def mapping_tenant_condition
    ([ mapping_owner_conditions ] + mapping_reviewer_conditions).join(" AND ")
  end

  def mapping_owner_conditions
    <<~SQL.squish
      staged_closeout_mappings.account_id = paid_current_account_id()
      AND EXISTS (
        SELECT 1 FROM projects
        WHERE projects.id = staged_closeout_mappings.project_id
          AND projects.account_id = paid_current_account_id()
      )
      AND EXISTS (
        SELECT 1 FROM issues
        INNER JOIN projects ON projects.id = issues.project_id
        WHERE issues.id = staged_closeout_mappings.issue_id
          AND issues.project_id = staged_closeout_mappings.project_id
          AND projects.account_id = paid_current_account_id()
      )
      AND EXISTS (
        SELECT 1 FROM staged_closeout_enrollments
        WHERE staged_closeout_enrollments.id = staged_closeout_mappings.staged_closeout_enrollment_id
          AND staged_closeout_enrollments.project_id = staged_closeout_mappings.project_id
          AND staged_closeout_enrollments.account_id = paid_current_account_id()
      )
    SQL
  end

  def mapping_reviewer_conditions
    conditions = [ user_reference_condition("reviewed_by_id") ]
    conditions << optional_user_reference_condition("invalidated_by_id") if column_exists?(:staged_closeout_mappings, :invalidated_by_id)
    conditions
  end

  def user_reference_condition(foreign_key)
    <<~SQL.squish
      EXISTS (
        SELECT 1 FROM users
        WHERE users.id = staged_closeout_mappings.#{foreign_key}
          AND users.account_id = paid_current_account_id()
      )
    SQL
  end

  def optional_user_reference_condition(foreign_key)
    <<~SQL.squish
      (
        staged_closeout_mappings.#{foreign_key} IS NULL
        OR #{user_reference_condition(foreign_key)}
      )
    SQL
  end
end
