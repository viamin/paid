# frozen_string_literal: true

# @spec UNIFIED-WORK-ITEMS-005
class AddWorkItemForeignKeyToAgentRuns < ActiveRecord::Migration[8.1]
  def change
    add_foreign_key :agent_runs, :work_items, validate: false
  end
end
