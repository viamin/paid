# frozen_string_literal: true

class RemoveRedundantRunnerAuthAttemptIndexes < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  # @spec POSTGRESQL-PERSISTENCE-015
  def up
    remove_index :runner_auth_attempts, name: "index_runner_auth_attempts_on_account_id", algorithm: :concurrently, if_exists: true
    remove_index :runner_auth_attempts, name: "index_runner_auth_attempts_on_agent_run_id", algorithm: :concurrently, if_exists: true
    remove_index :runner_auth_attempts, name: "index_runner_auth_attempts_on_project_id", algorithm: :concurrently, if_exists: true
  end

  def down
    add_index :runner_auth_attempts, :account_id, algorithm: :concurrently, if_not_exists: true
    add_index :runner_auth_attempts, :agent_run_id, algorithm: :concurrently, if_not_exists: true
    add_index :runner_auth_attempts, :project_id, algorithm: :concurrently, if_not_exists: true
  end
end
