# frozen_string_literal: true

class RemoveDuplicateExecutionUsageAgentRunIndex < ActiveRecord::Migration[8.1]
  def change
    return unless table_exists?(:execution_usages)
    return unless index_exists?(:execution_usages, :agent_run_id, name: "index_execution_usages_on_agent_run_id")

    remove_index :execution_usages, name: "index_execution_usages_on_agent_run_id"
  end
end
