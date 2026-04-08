# frozen_string_literal: true

class ChangeDefaultMaxExecutionSecondsTo3600 < ActiveRecord::Migration[8.1]
  def up
    change_column_default :projects, :max_execution_seconds, from: 1800, to: 3600
    change_column_default :user_settings, :container_timeout_seconds, from: 1800, to: 3600

    # Safe to backfill projects — max_execution_seconds is not user-editable via UI,
    # so any row at 1800 still holds the old default.
    Project.where(max_execution_seconds: 1800).update_all(max_execution_seconds: 3600)

    # Skip backfill for user_settings — container_timeout_seconds is user-editable
    # (Settings > Container Timeout), so a value of 1800 may be an intentional choice.
    # New records will pick up the 3600 default; existing users keep their setting.
  end

  def down
    change_column_default :projects, :max_execution_seconds, from: 3600, to: 1800
    change_column_default :user_settings, :container_timeout_seconds, from: 3600, to: 1800

    Project.where(max_execution_seconds: 3600).update_all(max_execution_seconds: 1800)
  end
end
