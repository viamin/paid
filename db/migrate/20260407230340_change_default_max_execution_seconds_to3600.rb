# frozen_string_literal: true

class ChangeDefaultMaxExecutionSecondsTo3600 < ActiveRecord::Migration[8.1]
  def up
    change_column_default :projects, :max_execution_seconds, from: 1800, to: 3600
    change_column_default :user_settings, :container_timeout_seconds, from: 1800, to: 3600

    Project.where(max_execution_seconds: 1800).update_all(max_execution_seconds: 3600)
    UserSetting.where(container_timeout_seconds: 1800).update_all(container_timeout_seconds: 3600)
  end

  def down
    change_column_default :projects, :max_execution_seconds, from: 3600, to: 1800
    change_column_default :user_settings, :container_timeout_seconds, from: 3600, to: 1800

    Project.where(max_execution_seconds: 3600).update_all(max_execution_seconds: 1800)
    UserSetting.where(container_timeout_seconds: 3600).update_all(container_timeout_seconds: 1800)
  end
end
