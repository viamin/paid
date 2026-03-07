# frozen_string_literal: true

class ReplaceContainerCpuQuotaWithMaxConcurrentRuns < ActiveRecord::Migration[8.1]
  def up
    add_column :user_settings, :max_concurrent_runs, :integer, default: 2, null: false

    execute <<~SQL.squish
      UPDATE user_settings
      SET max_concurrent_runs = LEAST(GREATEST(container_cpu_quota / 100000, 1), 8)
      WHERE container_cpu_quota IS NOT NULL
    SQL

    remove_column :user_settings, :container_cpu_quota, :integer, default: 200_000, null: false
  end

  def down
    add_column :user_settings, :container_cpu_quota, :integer, default: 200_000, null: false

    execute <<~SQL.squish
      UPDATE user_settings
      SET container_cpu_quota = max_concurrent_runs * 100000
      WHERE max_concurrent_runs IS NOT NULL
    SQL

    remove_column :user_settings, :max_concurrent_runs, :integer, default: 2, null: false
  end
end
