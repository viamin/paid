# frozen_string_literal: true

class AddExternalExecutionFieldsToAgentRuns < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def change
    add_column :agent_runs, :execution_origin, :string,
      default: "paid_native",
      null: false,
      comment: "Whether the run executed inside Paid or was ingested from an external toolchain."
    add_column :agent_runs, :external_source_key, :string,
      comment: "External system that executed the run, such as github_copilot, cursor, devin, factory, or internal_agent_workflows."
    add_column :agent_runs, :external_run_key, :string,
      comment: "Stable external run identifier used for idempotent ingestion."
    add_column :agent_runs, :adoption_mode_snapshot, :string,
      comment: "Project adoption mode captured when an external execution was ingested."
    add_column :agent_runs, :external_metadata, :jsonb,
      default: {},
      null: false,
      comment: "Structured metadata captured from external execution and migration workflows."

    add_index :agent_runs, :execution_origin, algorithm: :concurrently
    add_index :agent_runs,
      [ :project_id, :external_source_key, :external_run_key ],
      unique: true,
      where: "external_run_key IS NOT NULL",
      name: "idx_agent_runs_external_dedup",
      algorithm: :concurrently
  end
end
