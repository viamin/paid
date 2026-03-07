# frozen_string_literal: true

class ReplaceCpuQuotaWithMaxConcurrentRuns < ActiveRecord::Migration[8.1]
  # Replaces container_cpu_quota with max_concurrent_runs on user_settings.
  # Ensures the final schema is consistent: max_concurrent_runs present,
  # container_cpu_quota removed.
  #
  # NOTE: This migration was rewritten within PR #301 before merge.
  # It has not been applied to any environment in its prior form. If it has
  # already run (e.g. during development), re-run via:
  #   `bin/rails db:migrate:redo VERSION=20260307130000`
  def up
    unless column_exists?(:user_settings, :max_concurrent_runs)
      add_column :user_settings, :max_concurrent_runs, :integer, default: 2, null: false
    end

    remove_column :user_settings, :container_cpu_quota if column_exists?(:user_settings, :container_cpu_quota)
  end

  def down
    raise ActiveRecord::IrreversibleMigration, "ReplaceCpuQuotaWithMaxConcurrentRuns cannot be safely reversed"
  end
end
