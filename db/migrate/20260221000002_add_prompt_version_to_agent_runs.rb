# frozen_string_literal: true

class AddPromptVersionToAgentRuns < ActiveRecord::Migration[8.1]
  def change
    add_reference :agent_runs, :prompt_version, null: true, foreign_key: { on_delete: :nullify }
  end
end
