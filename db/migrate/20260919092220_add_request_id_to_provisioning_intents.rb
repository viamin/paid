# frozen_string_literal: true

class AddRequestIdToProvisioningIntents < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def up
    return unless table_exists?(:provisioning_intents)

    unless column_exists?(:provisioning_intents, :request_id)
      add_column :provisioning_intents, :request_id, :string, limit: 200,
        comment: "Caller idempotency key, unique per agent run and runner type when present."
    end

    return if index_exists?(:provisioning_intents, [ :agent_run_id, :runner_type, :request_id ],
      name: "index_provisioning_intents_on_run_runner_request")

    add_index :provisioning_intents, [ :agent_run_id, :runner_type, :request_id ],
      unique: true,
      where: "request_id IS NOT NULL",
      name: "index_provisioning_intents_on_run_runner_request",
      algorithm: :concurrently
  end

  def down
    return unless table_exists?(:provisioning_intents)

    remove_index :provisioning_intents,
      name: "index_provisioning_intents_on_run_runner_request",
      algorithm: :concurrently,
      if_exists: true
    remove_column :provisioning_intents, :request_id if column_exists?(:provisioning_intents, :request_id)
  end
end
