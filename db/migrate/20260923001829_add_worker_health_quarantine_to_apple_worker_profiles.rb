# frozen_string_literal: true

# @spec APPLE-ATTEMPT-015
class AddWorkerHealthQuarantineToAppleWorkerProfiles < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def up
    add_quarantine_columns
    add_health_failure_index
    add_returned_to_service_index
    add_returned_to_service_foreign_key
  end

  def down
    remove_returned_to_service_foreign_key
    remove_returned_to_service_index
    remove_health_failure_index
    remove_quarantine_columns
  end

  private

  def add_quarantine_columns
    add_quarantine_column :consecutive_health_failures, :integer,
      default: 0, null: false,
      comment: "Consecutive worker health failures; quarantine triggers when this crosses the configured threshold."
    add_quarantine_column :last_health_failure_at, :datetime,
      comment: "Timestamp of the most recent worker health failure; null when none recorded."
    add_quarantine_column :quarantined_at, :datetime,
      comment: "Timestamp the worker was quarantined; null when not quarantined."
    add_quarantine_column :quarantine_reason, :text,
      comment: "Operator-visible reason for the quarantine."
    add_quarantine_column :returned_to_service_at, :datetime,
      comment: "Timestamp the worker was last returned to service after quarantine."
    add_quarantine_column :returned_to_service_by_id, :bigint,
      comment: "Operator who returned the worker to service after the isolation smoke test."
  end

  def remove_quarantine_columns
    %i[
      returned_to_service_by_id
      returned_to_service_at
      quarantine_reason
      quarantined_at
      last_health_failure_at
      consecutive_health_failures
    ].each { |column| remove_quarantine_column(column) }
  end

  def add_quarantine_column(name, type, **options)
    return if column_exists?(:apple_worker_profiles, name)

    add_column :apple_worker_profiles, name, type, **options
  end

  def remove_quarantine_column(name)
    remove_column :apple_worker_profiles, name if column_exists?(:apple_worker_profiles, name)
  end

  def add_health_failure_index
    return if index_exists?(:apple_worker_profiles, :quarantined_at, name: "idx_apple_worker_profiles_quarantined")

    add_index :apple_worker_profiles, :quarantined_at,
      where: "quarantined_at IS NOT NULL",
      name: "idx_apple_worker_profiles_quarantined",
      algorithm: :concurrently
  end

  def remove_health_failure_index
    return unless index_exists?(:apple_worker_profiles, name: "idx_apple_worker_profiles_quarantined")

    remove_index :apple_worker_profiles, name: "idx_apple_worker_profiles_quarantined", algorithm: :concurrently
  end

  def add_returned_to_service_index
    return if index_exists?(:apple_worker_profiles, :returned_to_service_by_id,
      name: "index_apple_worker_profiles_on_returned_to_service_by_id")

    add_index :apple_worker_profiles, :returned_to_service_by_id,
      name: "index_apple_worker_profiles_on_returned_to_service_by_id",
      algorithm: :concurrently
  end

  def remove_returned_to_service_index
    return unless index_exists?(:apple_worker_profiles,
      name: "index_apple_worker_profiles_on_returned_to_service_by_id")

    remove_index :apple_worker_profiles,
      name: "index_apple_worker_profiles_on_returned_to_service_by_id",
      algorithm: :concurrently
  end

  def add_returned_to_service_foreign_key
    return if foreign_key_exists?(:apple_worker_profiles, :users,
      column: :returned_to_service_by_id)

    add_foreign_key :apple_worker_profiles, :users, column: :returned_to_service_by_id,
      validate: false
  end

  def remove_returned_to_service_foreign_key
    return unless foreign_key_exists?(:apple_worker_profiles, :users,
      column: :returned_to_service_by_id)

    remove_foreign_key :apple_worker_profiles, :users, column: :returned_to_service_by_id
  end
end
