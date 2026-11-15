# frozen_string_literal: true

# @spec UNIFIED-WORK-ITEMS-005
class ValidateWorkItemForeignKeyOnAgentRuns < ActiveRecord::Migration[8.1]
  def change
    validate_foreign_key :agent_runs, :work_items
  end
end
