# frozen_string_literal: true

class AdjustDefaultAgentRunTimeouts < ActiveRecord::Migration[8.1]
  NEW_AGENT_TIMEOUT_SECONDS = 5400
  NEW_MAX_EXECUTION_SECONDS = 7200

  class MigrationProject < ApplicationRecord
    self.table_name = "projects"
  end

  class MigrationUserSetting < ApplicationRecord
    self.table_name = "user_settings"
  end

  def up
    change_column_default :user_settings, :agent_timeout_seconds, from: 3600, to: NEW_AGENT_TIMEOUT_SECONDS
    change_column_default :projects, :max_execution_seconds, from: 3600, to: NEW_MAX_EXECUTION_SECONDS

    MigrationUserSetting.where(agent_timeout_seconds: 3600)
      .where("updated_at = created_at")
      .update_all(agent_timeout_seconds: NEW_AGENT_TIMEOUT_SECONDS) # rubocop:disable Rails/SkipsModelValidations
    MigrationProject.where(max_execution_seconds: 3600)
      .where("updated_at = created_at")
      .update_all(max_execution_seconds: NEW_MAX_EXECUTION_SECONDS) # rubocop:disable Rails/SkipsModelValidations
  end

  def down
    MigrationUserSetting.where(agent_timeout_seconds: NEW_AGENT_TIMEOUT_SECONDS)
      .where("updated_at = created_at")
      .update_all(agent_timeout_seconds: 3600) # rubocop:disable Rails/SkipsModelValidations
    MigrationProject.where(max_execution_seconds: NEW_MAX_EXECUTION_SECONDS)
      .where("updated_at = created_at")
      .update_all(max_execution_seconds: 3600) # rubocop:disable Rails/SkipsModelValidations

    change_column_default :user_settings, :agent_timeout_seconds, from: NEW_AGENT_TIMEOUT_SECONDS, to: 3600
    change_column_default :projects, :max_execution_seconds, from: NEW_MAX_EXECUTION_SECONDS, to: 3600
  end
end
