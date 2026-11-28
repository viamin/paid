# frozen_string_literal: true

class RemoveRedundantRunnerCredentialsAccountIdIndex < ActiveRecord::Migration[8.1] # @spec POSTGRESQL-PERSISTENCE-014
  INDEX_NAME = "index_runner_credentials_on_account_id"
  COVERING_INDEX_NAME = "index_runner_credentials_on_account_id_and_revoked_at"

  disable_ddl_transaction!

  def up
    remove_index :runner_credentials, name: INDEX_NAME, algorithm: :concurrently, if_exists: true
  end

  def down
    add_index :runner_credentials, :account_id, name: INDEX_NAME,
      algorithm: :concurrently, if_not_exists: true
  end
end
