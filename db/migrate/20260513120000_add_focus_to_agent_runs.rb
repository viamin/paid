# frozen_string_literal: true

class AddFocusToAgentRuns < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def up
    unless column_exists?(:agent_runs, :focus)
      add_column :agent_runs, :focus, :string,
        limit: 50,
        default: "general",
        null: false,
        comment: "Focused run intent derived from the highest-priority PR trigger or assigned workflow context."
    end

    return if index_exists?(:agent_runs, :focus)

    add_index :agent_runs, :focus, algorithm: :concurrently
  end

  def down
    remove_index :agent_runs, :focus, algorithm: :concurrently if index_exists?(:agent_runs, :focus)
    remove_column :agent_runs, :focus if column_exists?(:agent_runs, :focus)
  end
end
