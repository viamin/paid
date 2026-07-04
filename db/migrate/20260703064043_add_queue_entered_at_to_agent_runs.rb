# frozen_string_literal: true

class AddQueueEnteredAtToAgentRuns < ActiveRecord::Migration[8.1]
  class MigrationAgentRun < ApplicationRecord
    self.table_name = "agent_runs"
  end

  def up
    add_column :agent_runs, :queue_entered_at, :datetime,
      comment: "Most recent time this run entered queued status so queue latency metrics reflect the current queue episode."

    MigrationAgentRun.update_all("queue_entered_at = created_at")
  end

  def down
    remove_column :agent_runs, :queue_entered_at
  end
end
