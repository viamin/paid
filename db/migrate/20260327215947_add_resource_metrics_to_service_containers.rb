class AddResourceMetricsToServiceContainers < ActiveRecord::Migration[8.1]
  def change
    add_column :service_containers, :peak_cpu_percent, :float
    add_column :service_containers, :peak_memory_bytes, :bigint
    add_column :service_containers, :avg_cpu_percent, :float
    add_column :service_containers, :avg_memory_bytes, :decimal, precision: 20, scale: 4
    add_column :service_containers, :container_metrics_count, :integer, default: 0, null: false
  end
end
