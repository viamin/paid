# frozen_string_literal: true

class ReplaceContainerCpuQuotaWithMaxConcurrentRuns < ActiveRecord::Migration[8.1]
  def change
    add_column :user_settings, :max_concurrent_runs, :integer, default: 2, null: false
    remove_column :user_settings, :container_cpu_quota, :integer, default: 200_000, null: false
  end
end
