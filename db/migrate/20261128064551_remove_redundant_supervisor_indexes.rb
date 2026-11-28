# frozen_string_literal: true

class RemoveRedundantSupervisorIndexes < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  # @spec POSTGRESQL-PERSISTENCE-023
  def up
    remove_index :supervisor_incident_audits, name: "index_supervisor_incident_audits_on_supervisor_incident_id", algorithm: :concurrently, if_exists: true
    remove_index :supervisor_incidents, name: "index_supervisor_incidents_on_account_id", algorithm: :concurrently, if_exists: true
    remove_index :supervisor_snapshots, name: "index_supervisor_snapshots_on_account_id", algorithm: :concurrently, if_exists: true
  end

  def down
    add_index :supervisor_incident_audits, :supervisor_incident_id, algorithm: :concurrently, if_not_exists: true
    add_index :supervisor_incidents, :account_id, algorithm: :concurrently, if_not_exists: true
    add_index :supervisor_snapshots, :account_id, algorithm: :concurrently, if_not_exists: true
  end
end
