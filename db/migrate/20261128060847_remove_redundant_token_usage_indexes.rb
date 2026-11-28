# frozen_string_literal: true

class RemoveRedundantTokenUsageIndexes < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  # @spec POSTGRESQL-PERSISTENCE-020
  def up
    remove_index :token_usages, name: "index_token_usages_on_knowledge_run_id", algorithm: :concurrently, if_exists: true
    remove_index :token_usages, name: "index_token_usages_on_request_type", algorithm: :concurrently, if_exists: true
  end

  def down
    add_index :token_usages, :knowledge_run_id, algorithm: :concurrently, if_not_exists: true
    add_index :token_usages, :request_type, algorithm: :concurrently, if_not_exists: true
  end
end
