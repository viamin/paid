# frozen_string_literal: true

class AddFocusToAgentRuns < ActiveRecord::Migration[8.1]
  def change
    add_column :agent_runs, :focus, :string,
      limit: 50,
      default: "general",
      null: false,
      comment: "Focused run intent derived from the highest-priority PR trigger or assigned workflow context."
    add_index :agent_runs, :focus
  end
end
