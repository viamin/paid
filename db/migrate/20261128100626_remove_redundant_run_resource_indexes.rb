# frozen_string_literal: true

class RemoveRedundantRunResourceIndexes < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  # @spec POSTGRESQL-PERSISTENCE-029
  def up
    remove_index :provisioning_intents, name: "index_provisioning_intents_on_agent_run_id", algorithm: :concurrently, if_exists: true
    remove_index :runner_auth_materializations, name: "index_runner_auth_materializations_on_agent_run_id", algorithm: :concurrently, if_exists: true
  end

  def down
    add_index :provisioning_intents, :agent_run_id, algorithm: :concurrently, if_not_exists: true
    add_index :runner_auth_materializations, :agent_run_id, algorithm: :concurrently, if_not_exists: true
  end
end
