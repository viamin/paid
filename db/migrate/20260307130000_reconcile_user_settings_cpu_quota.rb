# frozen_string_literal: true

class ReconcileUserSettingsCpuQuota < ActiveRecord::Migration[8.1]
  def up
    unless column_exists?(:user_settings, :container_cpu_quota)
      add_column :user_settings, :container_cpu_quota, :integer, default: 200_000, null: false
    end

    remove_column :user_settings, :max_concurrent_runs if column_exists?(:user_settings, :max_concurrent_runs)
  end

  def down
    raise ActiveRecord::IrreversibleMigration, "ReconcileUserSettingsCpuQuota cannot be safely reversed"
  end
end
