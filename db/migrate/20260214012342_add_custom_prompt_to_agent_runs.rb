class AddCustomPromptToAgentRuns < ActiveRecord::Migration[8.1]
  def change
    add_column :agent_runs, :custom_prompt, :text
  end
end
