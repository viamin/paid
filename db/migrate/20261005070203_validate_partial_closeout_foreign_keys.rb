# frozen_string_literal: true

class ValidatePartialCloseoutForeignKeys < ActiveRecord::Migration[8.1]
  def up
    validate_foreign_key :agent_runs, :issue_continuation_requests
    validate_foreign_key :issues, :users
  end

  def down
  end
end
