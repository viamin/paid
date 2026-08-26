# frozen_string_literal: true

class CreateExecutionResourceCleanups < ActiveRecord::Migration[8.1]
  def change
    create_table :execution_resource_cleanups,
      comment: "Durable retry queue for cleanup of runner-managed external execution resources." do |t|
      t.references :account, null: true, foreign_key: { on_delete: :nullify },
        comment: "Owning account when known."
      t.references :project, null: true, foreign_key: { on_delete: :nullify },
        comment: "Owning project when known."
      t.references :agent_run, null: true, foreign_key: { on_delete: :nullify },
        comment: "Owning agent run when known."
      t.references :provisioning_intent, null: true, foreign_key: { on_delete: :nullify },
        comment: "Crash-window provisioning intent that led to this cleanup request, when present."
      t.string :runner_type, null: false, limit: 50, comment: "Runner type used to clean up the resource."
      t.string :resource_kind, null: false, limit: 100, comment: "Runner-declared resource kind."
      t.string :provider_resource_id, null: false, limit: 200, comment: "Provider identifier of the resource to delete."
      t.string :provider_resource_host, null: false, default: "", limit: 200,
        comment: "Owning backend host when applicable; blank when the provider has no host-local identity."
      t.jsonb :ownership_tags, null: false, default: {},
        comment: "Stable Paid ownership tags copied from the live resource or provisioning intent."
      t.string :status, null: false, default: "pending", limit: 50,
        comment: "Cleanup queue state: pending | completed."
      t.integer :attempts, null: false, default: 0, comment: "Number of failed cleanup attempts."
      t.datetime :next_attempt_at, null: false, comment: "When the cleanup should be retried next."
      t.datetime :last_attempted_at, comment: "When cleanup was last attempted."
      t.text :last_error, comment: "Last transient cleanup error."
      t.datetime :completed_at, comment: "When cleanup was confirmed complete."
      t.timestamps

      t.index [ :status, :next_attempt_at ], name: "index_execution_resource_cleanups_on_status_and_next_attempt_at"
      t.index [ :runner_type, :resource_kind, :provider_resource_id, :provider_resource_host ],
        unique: true,
        name: "index_execution_resource_cleanups_on_provider_reference"
    end
  end
end
