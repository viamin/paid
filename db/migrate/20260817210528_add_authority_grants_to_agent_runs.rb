# frozen_string_literal: true

class AddAuthorityGrantsToAgentRuns < ActiveRecord::Migration[8.1]
  def change
    return if column_exists?(:agent_runs, :authority_grants)

    add_column :agent_runs, :authority_grants, :jsonb, null: false, default: {},
      comment: "Secret-free execution authority grant snapshot for the run"
  end
end
