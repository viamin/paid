# frozen_string_literal: true

class CreateAppleVerificationWorkerHealths < ActiveRecord::Migration[8.1]
  def up
    unless table_exists?(:apple_verification_worker_healths)
      create_table :apple_verification_worker_healths, comment: "Persistent scheduling health and quarantine state for Apple verification workers." do |t|
        t.references :apple_worker_profile, null: false, foreign_key: true, index: { unique: true }, comment: "Worker profile whose scheduler health this row tracks."
        t.string :status, null: false, default: "healthy", comment: "healthy or quarantined; quarantined workers cannot receive new attempts."
        t.integer :consecutive_failures, null: false, default: 0, comment: "Consecutive infrastructure health failures observed by the scheduler."
        t.datetime :quarantined_at, comment: "Time admission was stopped for repeated health failures."
        t.datetime :isolation_smoke_tested_at, comment: "Passing isolation smoke-test time required before return to service."
        t.timestamps
      end
    end

    add_check_constraint :apple_verification_worker_healths, "status IN ('healthy', 'quarantined')", name: "chk_apple_worker_health_status" unless check_constraint_exists?(:apple_verification_worker_healths, name: "chk_apple_worker_health_status")
    add_check_constraint :apple_verification_worker_healths, "consecutive_failures >= 0", name: "chk_apple_worker_health_failures" unless check_constraint_exists?(:apple_verification_worker_healths, name: "chk_apple_worker_health_failures")
    enable_tenant_row_level_security
  end

  def down
    disable_tenant_row_level_security
    drop_table :apple_verification_worker_healths if table_exists?(:apple_verification_worker_healths)
  end

  private

  def enable_tenant_row_level_security
    return unless table_exists?(:apple_verification_worker_healths)

    safety_assured do
      execute "ALTER TABLE apple_verification_worker_healths ENABLE ROW LEVEL SECURITY"
      execute "ALTER TABLE apple_verification_worker_healths FORCE ROW LEVEL SECURITY"
      execute "DROP POLICY IF EXISTS tenant_isolation ON apple_verification_worker_healths"
      execute <<~SQL
        CREATE POLICY tenant_isolation ON apple_verification_worker_healths
        AS PERMISSIVE
        FOR ALL
        USING (paid_tenant_bypass() OR EXISTS (
          SELECT 1 FROM apple_worker_profiles
          WHERE apple_worker_profiles.id = apple_verification_worker_healths.apple_worker_profile_id
            AND apple_worker_profiles.account_id = paid_current_account_id()
        ))
        WITH CHECK (paid_tenant_bypass() OR EXISTS (
          SELECT 1 FROM apple_worker_profiles
          WHERE apple_worker_profiles.id = apple_verification_worker_healths.apple_worker_profile_id
            AND apple_worker_profiles.account_id = paid_current_account_id()
        ))
      SQL
    end
  end

  def disable_tenant_row_level_security
    return unless table_exists?(:apple_verification_worker_healths)

    safety_assured do
      execute "DROP POLICY IF EXISTS tenant_isolation ON apple_verification_worker_healths"
      execute "ALTER TABLE apple_verification_worker_healths NO FORCE ROW LEVEL SECURITY"
      execute "ALTER TABLE apple_verification_worker_healths DISABLE ROW LEVEL SECURITY"
    end
  end
end
