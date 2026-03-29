# frozen_string_literal: true

class AddProviderToAgentRuns < ActiveRecord::Migration[8.1]
  def change
    add_reference :agent_runs, :provider, null: true, foreign_key: true
  end
end
