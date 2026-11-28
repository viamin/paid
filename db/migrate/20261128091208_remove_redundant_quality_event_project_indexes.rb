# frozen_string_literal: true

class RemoveRedundantQualityEventProjectIndexes < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  # @spec POSTGRESQL-PERSISTENCE-027
  def up
    remove_index :quality_gate_events, name: "index_quality_gate_events_on_project_id", algorithm: :concurrently, if_exists: true
    remove_index :quality_pause_events, name: "index_quality_pause_events_on_project_id", algorithm: :concurrently, if_exists: true
    remove_index :quality_recovery_actions, name: "index_quality_recovery_actions_on_project_id", algorithm: :concurrently, if_exists: true
  end

  def down
    add_index :quality_gate_events, :project_id, algorithm: :concurrently, if_not_exists: true
    add_index :quality_pause_events, :project_id, algorithm: :concurrently, if_not_exists: true
    add_index :quality_recovery_actions, :project_id, algorithm: :concurrently, if_not_exists: true
  end
end
