# frozen_string_literal: true

class AddAuthExpiredProviderToAgentRuns < ActiveRecord::Migration[8.1]
  def change
    add_column :agent_runs, :auth_provider, :string, limit: 50
  end
end
