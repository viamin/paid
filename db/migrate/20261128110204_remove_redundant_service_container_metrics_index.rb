# frozen_string_literal: true

class RemoveRedundantServiceContainerMetricsIndex < ActiveRecord::Migration[8.1] # @spec POSTGRESQL-PERSISTENCE-014
  disable_ddl_transaction!

  REDUNDANT_INDEX = "index_service_container_metrics_on_service_container_id"
  COVERING_INDEX = "index_service_container_metrics_on_container_and_recorded"

  def up
    remove_index :service_container_metrics, name: REDUNDANT_INDEX,
      algorithm: :concurrently, if_exists: true
  end

  def down
    add_index :service_container_metrics, :service_container_id, name: REDUNDANT_INDEX,
      algorithm: :concurrently unless index_exists?(:service_container_metrics, name: REDUNDANT_INDEX)
  end
end
