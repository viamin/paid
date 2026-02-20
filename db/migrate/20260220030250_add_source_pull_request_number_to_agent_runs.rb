class AddSourcePullRequestNumberToAgentRuns < ActiveRecord::Migration[8.1]
  def change
    add_column :agent_runs, :source_pull_request_number, :integer
  end
end
