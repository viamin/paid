# frozen_string_literal: true

class ReplaceSortingIndexesWithComposite < ActiveRecord::Migration[8.1]
  def change
    remove_index :projects, :last_agent_run_at
    remove_index :projects, :last_github_activity_at

    add_index :projects, [ :account_id, :last_agent_run_at ]
    add_index :projects, [ :account_id, :last_github_activity_at ]
  end
end
