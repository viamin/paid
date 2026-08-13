# frozen_string_literal: true

class BackfillProxyTokensOnAgentRuns < ActiveRecord::Migration[8.1]
  def up
    agent_run_class = Class.new(ActiveRecord::Base) do
      self.table_name = "agent_runs"
    end

    agent_run_class.reset_column_information

    agent_run_class.where(proxy_token: nil).find_each do |run|
      agent_run_class.where(id: run.id, proxy_token: nil).update_all(proxy_token: SecureRandom.hex(32))
    end
  end

  def down
    # No-op: removing tokens would break running agents
  end
end
