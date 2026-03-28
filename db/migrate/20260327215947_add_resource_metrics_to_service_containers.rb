# frozen_string_literal: true

class AddResourceMetricsToServiceContainers < ActiveRecord::Migration[8.1]
  def change
    change_table :service_containers, bulk: true do |t|
      t.float :peak_cpu_percent
      t.bigint :peak_memory_bytes
      t.float :avg_cpu_percent
      t.decimal :avg_memory_bytes, precision: 20, scale: 4
      t.integer :container_metrics_count, default: 0, null: false
    end
  end
end
