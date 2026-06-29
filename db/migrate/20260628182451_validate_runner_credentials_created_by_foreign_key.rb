# frozen_string_literal: true

class ValidateRunnerCredentialsCreatedByForeignKey < ActiveRecord::Migration[8.1]
  def change
    validate_foreign_key :runner_credentials, :users
  end
end
