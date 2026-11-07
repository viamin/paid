# frozen_string_literal: true

class CreateTrustedMeasurementAttempts < ActiveRecord::Migration[8.1]
  def up
    create_table :trusted_measurement_attempts do |t|
      t.references :account, null: false, foreign_key: true
      t.references :project, null: false, foreign_key: true
      t.references :issue, foreign_key: true
      t.integer :external_issue_number, null: false
      t.string :criterion_key, null: false
      t.string :check_key, null: false
      t.integer :check_version, null: false, default: 1
      t.string :deployed_revision
      t.string :status, null: false, default: "pending"
      t.jsonb :result, null: false, default: {}
      t.string :failure_reason
      t.datetime :executed_at
      t.timestamps
    end

    add_index :trusted_measurement_attempts,
      [ :project_id, :check_key, :check_version, :deployed_revision, :criterion_key, :external_issue_number ],
      unique: true, name: "index_trusted_measurement_attempts_on_identity"
    add_index :trusted_measurement_attempts, [ :project_id, :status ]

    enable_tenant_rls
  end

  def down
    disable_tenant_rls
    drop_table :trusted_measurement_attempts
  end

  def enable_tenant_rls
    safety_assured do
      execute "ALTER TABLE trusted_measurement_attempts ENABLE ROW LEVEL SECURITY"
      execute "ALTER TABLE trusted_measurement_attempts FORCE ROW LEVEL SECURITY"
      execute "DROP POLICY IF EXISTS tenant_isolation ON trusted_measurement_attempts"
      execute <<~SQL
        CREATE POLICY tenant_isolation ON trusted_measurement_attempts
        AS PERMISSIVE
        FOR ALL
        USING (paid_tenant_bypass() OR (#{tenant_condition}))
        WITH CHECK (paid_tenant_bypass() OR (#{tenant_condition}))
      SQL
    end
  end

  def disable_tenant_rls
    safety_assured do
      execute "DROP POLICY IF EXISTS tenant_isolation ON trusted_measurement_attempts"
      execute "ALTER TABLE trusted_measurement_attempts NO FORCE ROW LEVEL SECURITY"
      execute "ALTER TABLE trusted_measurement_attempts DISABLE ROW LEVEL SECURITY"
    end
  end

  private

  def tenant_condition
    <<~SQL.squish
      trusted_measurement_attempts.account_id = paid_current_account_id()
      AND EXISTS (
        SELECT 1 FROM projects
        WHERE projects.id = trusted_measurement_attempts.project_id
          AND projects.account_id = paid_current_account_id()
      )
      AND (
        trusted_measurement_attempts.issue_id IS NULL
        OR EXISTS (
          SELECT 1 FROM issues
          WHERE issues.id = trusted_measurement_attempts.issue_id
            AND issues.project_id = trusted_measurement_attempts.project_id
        )
      )
    SQL
  end
end
