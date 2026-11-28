# @spec POSTGRESQL-PERSISTENCE-014
class RemoveRedundantRunnerCredentialsAccountRunnerKeyIndex < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  INDEX_NAME = "index_runner_credentials_on_account_id_and_runner_key"
  COVERING_INDEX_NAME = "idx_runner_credentials_on_account_runner_key_name"

  def up
    remove_index :runner_credentials,
      name: INDEX_NAME,
      algorithm: :concurrently,
      if_exists: true
  end

  def down
    add_index :runner_credentials, [ :account_id, :runner_key ],
      name: INDEX_NAME,
      algorithm: :concurrently,
      if_not_exists: true
  end
end
