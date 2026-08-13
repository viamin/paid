# frozen_string_literal: true

class AddInitiatingUserToAgentRuns < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def up
    add_reference :agent_runs,
      :initiating_user,
      null: true,
      index: { algorithm: :concurrently },
      comment: "User who explicitly initiated the run; null for system-triggered runs."
  end

  def down
    remove_reference :agent_runs, :initiating_user, index: { algorithm: :concurrently }
  end
end
