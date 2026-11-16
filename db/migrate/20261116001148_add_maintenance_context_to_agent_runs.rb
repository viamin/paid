# frozen_string_literal: true

# RDR-075 M01 (#4328): maintenance-run context snapshotted at start and kept
# immutable once the run exists. @spec MAINT-015
class AddMaintenanceContextToAgentRuns < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def change
    add_column :agent_runs, :maintenance_objective, :string, limit: 100,
      comment: "Recipe key for maintenance runs; nil for a free-text user question."
    add_column :agent_runs, :maintenance_recipe_version, :string, limit: 50,
      comment: "Effective recipe version snapshotted when the maintenance run started."
    add_column :agent_runs, :maintenance_scope, :text,
      comment: "Verbatim user-named scope (paths/symbols or free-form target) for maintenance runs; nil means broad scope."
    add_column :agent_runs, :maintenance_scope_kind, :string, limit: 10,
      comment: "Explicit scope classification recorded at maintenance run start: named or broad."
    add_column :agent_runs, :maintenance_guidance, :text,
      comment: "Free-text user guidance captured verbatim when the maintenance run started."
    add_column :agent_runs, :maintenance_pinned_revision, :string, limit: 255,
      comment: "Requested repository revision reference pinned at maintenance run start; the cloned SHA lands in base_commit_sha."
    add_column :agent_runs, :maintenance_limits, :jsonb,
      comment: "Effective cost/time limits snapshotted when the maintenance run started."

    add_index :agent_runs, [ :project_id, :goal ], name: "index_agent_runs_on_project_and_maintenance_goal",
      where: "goal = 'maintenance'", algorithm: :concurrently
  end
end
