class AddReviewUrlToAgentRuns < ActiveRecord::Migration[8.1]
  def change
    add_column :agent_runs, :review_url, :string
  end
end
