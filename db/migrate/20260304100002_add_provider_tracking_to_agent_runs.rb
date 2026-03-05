# frozen_string_literal: true

class AddProviderTrackingToAgentRuns < ActiveRecord::Migration[8.1]
  def change
    add_column :agent_runs, :providers_attempted, :jsonb, default: [], null: false
    add_column :agent_runs, :final_provider, :string, limit: 50
    add_column :agent_runs, :provider_switches, :integer, default: 0, null: false
  end
end
