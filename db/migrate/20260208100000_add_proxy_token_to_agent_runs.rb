# frozen_string_literal: true

class AddProxyTokenToAgentRuns < ActiveRecord::Migration[8.0]
  def change
    add_column :agent_runs, :proxy_token, :string, limit: 64
    add_index :agent_runs, :proxy_token, unique: true
  end
end
