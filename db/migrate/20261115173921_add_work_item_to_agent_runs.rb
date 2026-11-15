# frozen_string_literal: true

# @spec UNIFIED-WORK-ITEMS-005
class AddWorkItemToAgentRuns < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def change
    add_reference :agent_runs, :work_item, index: { algorithm: :concurrently }
  end
end
