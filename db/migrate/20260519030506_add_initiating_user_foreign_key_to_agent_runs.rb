# frozen_string_literal: true

class AddInitiatingUserForeignKeyToAgentRuns < ActiveRecord::Migration[8.1]
  def change
    add_foreign_key :agent_runs, :users,
      column: :initiating_user_id,
      on_delete: :nullify,
      validate: false
  end
end
