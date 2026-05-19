# frozen_string_literal: true

class ValidateInitiatingUserForeignKeyOnAgentRuns < ActiveRecord::Migration[8.1]
  def change
    validate_foreign_key :agent_runs, :users, column: :initiating_user_id
  end
end
