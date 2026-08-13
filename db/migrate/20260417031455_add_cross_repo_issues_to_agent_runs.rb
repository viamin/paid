# frozen_string_literal: true

class AddCrossRepoIssuesToAgentRuns < ActiveRecord::Migration[8.1]
  def change
    add_column :agent_runs, :cross_repo_issues, :jsonb, default: []
  end
end
