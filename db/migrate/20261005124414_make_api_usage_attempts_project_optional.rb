# frozen_string_literal: true

# @spec API-CONVERSATION-DELEGATION-002
class MakeApiUsageAttemptsProjectOptional < ActiveRecord::Migration[8.1]
  def up
    return unless table_exists?(:api_usage_attempts)
    return unless column_exists?(:api_usage_attempts, :project_id)

    change_column_null :api_usage_attempts, :project_id, true
  end

  def down
    raise ActiveRecord::IrreversibleMigration,
      "Cannot require a project while account-level API usage attempts exist"
  end
end
