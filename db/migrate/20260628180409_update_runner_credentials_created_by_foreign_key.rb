# frozen_string_literal: true

class UpdateRunnerCredentialsCreatedByForeignKey < ActiveRecord::Migration[8.1]
  def up
    remove_foreign_key :runner_credentials, column: :created_by_id
    add_foreign_key :runner_credentials, :users, column: :created_by_id, on_delete: :nullify, validate: false
  end

  def down
    remove_foreign_key :runner_credentials, column: :created_by_id
    add_foreign_key :runner_credentials, :users, column: :created_by_id
  end
end
