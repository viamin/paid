# frozen_string_literal: true

class AddQuarantineAndHealthToAppleWorkerProfiles < ActiveRecord::Migration[8.1]
  def change
    unless column_exists?(:apple_worker_profiles, :consecutive_health_failures)
      add_column :apple_worker_profiles, :consecutive_health_failures, :integer, null: false, default: 0,
        comment: "Consecutive worker health failures since the last passing smoke test."
    end

    unless column_exists?(:apple_worker_profiles, :quarantined_at)
      add_column :apple_worker_profiles, :quarantined_at, :datetime,
        comment: "When the profile was taken out of service for failing health checks."
    end

    unless column_exists?(:apple_worker_profiles, :quarantine_reason)
      add_column :apple_worker_profiles, :quarantine_reason, :string,
        comment: "Failure taxonomy reason recorded when the profile was quarantined."
    end

    unless column_exists?(:apple_worker_profiles, :returned_to_service_at)
      add_column :apple_worker_profiles, :returned_to_service_at, :datetime,
        comment: "When a quarantined profile was returned to service after a passing smoke test."
    end

    unless column_exists?(:apple_worker_profiles, :last_health_failure_at)
      add_column :apple_worker_profiles, :last_health_failure_at, :datetime,
        comment: "When the most recent health failure was observed for this profile."
    end

    unless column_exists?(:apple_worker_profiles, :last_smoke_test_passed_at)
      add_column :apple_worker_profiles, :last_smoke_test_passed_at, :datetime,
        comment: "When the profile last passed its smoke test."
    end
  end
end
