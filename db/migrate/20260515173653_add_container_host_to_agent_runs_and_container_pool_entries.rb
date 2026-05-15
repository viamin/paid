# frozen_string_literal: true

class AddContainerHostToAgentRunsAndContainerPoolEntries < ActiveRecord::Migration[8.1]
  def change
    add_column :agent_runs, :container_host, :string,
      default: "local", limit: 64,
      comment: "Container backend host identifier used to provision and reconnect to this run's container."
    add_column :container_pool_entries, :container_host, :string,
      default: "local", limit: 64,
      comment: "Container backend host identifier for the warmed container."
  end
end
