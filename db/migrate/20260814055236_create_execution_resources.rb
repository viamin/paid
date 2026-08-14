# frozen_string_literal: true

class CreateExecutionResources < ActiveRecord::Migration[8.1]
  def change
    create_table :execution_resources,
      comment: "Durable execution-resource ledger rows tracked against provider state for reconciliation and cleanup retry." do |t|
      t.references :account, foreign_key: true,
        comment: "Owning account for resources linked to a known Paid account."
      t.references :project, foreign_key: true,
        comment: "Owning project for resources linked to a known Paid project."
      t.references :agent_run, foreign_key: true,
        comment: "Agent run that owns the tracked environment when the resource is tied to a specific run."
      t.string :resource_type, null: false,
        comment: "Tracked execution resource type: environment or workspace."
      t.string :state, null: false, default: "active",
        comment: "Ledger lifecycle state: active, cleanup_pending, or cleaned."
      t.string :runner_type, null: false,
        comment: "Execution runner/provider type that owns the resource."
      t.string :identifier, null: false,
        comment: "Provider-native resource identifier."
      t.string :host, null: false, default: "",
        comment: "Owning backend host or empty string when the provider has no host dimension."
      t.jsonb :runner_handle,
        comment: "Persisted RunnerHandle used for handle-based cleanup when provider listing is unavailable."
      t.string :workspace_ref,
        comment: "Opaque workspace reference carried by the runner handle for cleanup and reconciliation."
      t.jsonb :tags, null: false, default: {},
        comment: "Provider-reported labels/tags captured for reconciliation and orphan adoption."
      t.jsonb :metadata, null: false, default: {},
        comment: "Provider-specific reconciliation metadata."
      t.boolean :reduced_confidence, null: false, default: false,
        comment: "True when reconciliation had to degrade without provider list/tag support."
      t.integer :cleanup_attempts, null: false, default: 0,
        comment: "How many durable cleanup retries have been recorded for this row."
      t.datetime :next_cleanup_at
      t.string :last_cleanup_error,
        comment: "Last cleanup failure message recorded for retry."
      t.string :last_cleanup_error_class,
        comment: "Class name of the last cleanup failure recorded for retry."
      t.datetime :last_cleanup_failed_at
      t.datetime :adopted_at
      t.datetime :cleaned_at
      t.datetime :reconciled_at

      t.timestamps
    end

    add_index :execution_resources, [ :runner_type, :host, :identifier ],
      unique: true, name: "idx_execution_resources_provider_identity"
    add_index :execution_resources, [ :agent_run_id, :resource_type ],
      unique: true, where: "agent_run_id IS NOT NULL",
      name: "idx_execution_resources_agent_run_resource_type"
    add_index :execution_resources, [ :state, :next_cleanup_at ],
      name: "idx_execution_resources_cleanup_schedule"
  end
end
