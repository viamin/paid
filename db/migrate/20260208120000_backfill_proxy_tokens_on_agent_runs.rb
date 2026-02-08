# frozen_string_literal: true

class BackfillProxyTokensOnAgentRuns < ActiveRecord::Migration[8.1]
  def up
    AgentRun.where(proxy_token: nil).find_each do |run|
      run.update_column(:proxy_token, SecureRandom.hex(32))
    end
  end

  def down
    # No-op: removing tokens would break running agents
  end
end
