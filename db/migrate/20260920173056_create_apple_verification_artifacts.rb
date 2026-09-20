# frozen_string_literal: true

class CreateAppleVerificationArtifacts < ActiveRecord::Migration[8.1]
  def up
    create_artifacts_table unless table_exists?(:apple_verification_artifacts)
    add_artifacts_index unless index_exists?(:apple_verification_artifacts, [ :apple_verification_attempt_id, :kind ])
    enable_tenant_row_level_security
  end

  def down
    disable_tenant_row_level_security
    drop_table :apple_verification_artifacts if table_exists?(:apple_verification_artifacts)
  end

  private

  def create_artifacts_table
    create_table :apple_verification_artifacts, comment: "Protected Apple verification result artifacts." do |t|
      t.references :apple_verification_attempt, null: false, foreign_key: true
      t.string :kind, null: false
      t.string :storage_key, null: false
      t.string :content_type
      t.jsonb :metadata, null: false, default: {}
      t.datetime :expires_at
      t.timestamps
    end
  end

  def add_artifacts_index
    add_index :apple_verification_artifacts, [ :apple_verification_attempt_id, :kind ]
  end

  def enable_tenant_row_level_security
    safety_assured do
      execute "ALTER TABLE apple_verification_artifacts ENABLE ROW LEVEL SECURITY"
      execute "ALTER TABLE apple_verification_artifacts FORCE ROW LEVEL SECURITY"
      execute "DROP POLICY IF EXISTS tenant_isolation ON apple_verification_artifacts"
      execute <<~SQL
        CREATE POLICY tenant_isolation ON apple_verification_artifacts
        AS PERMISSIVE
        FOR ALL
        USING (paid_tenant_bypass() OR EXISTS (
          SELECT 1 FROM apple_verification_attempts
          WHERE apple_verification_attempts.id = apple_verification_artifacts.apple_verification_attempt_id
            AND apple_verification_attempts.account_id = paid_current_account_id()
        ))
        WITH CHECK (paid_tenant_bypass() OR EXISTS (
          SELECT 1 FROM apple_verification_attempts
          WHERE apple_verification_attempts.id = apple_verification_artifacts.apple_verification_attempt_id
            AND apple_verification_attempts.account_id = paid_current_account_id()
        ))
      SQL
    end
  end

  def disable_tenant_row_level_security
    return unless table_exists?(:apple_verification_artifacts)

    safety_assured do
      execute "DROP POLICY IF EXISTS tenant_isolation ON apple_verification_artifacts"
      execute "ALTER TABLE apple_verification_artifacts NO FORCE ROW LEVEL SECURITY"
      execute "ALTER TABLE apple_verification_artifacts DISABLE ROW LEVEL SECURITY"
    end
  end
end
