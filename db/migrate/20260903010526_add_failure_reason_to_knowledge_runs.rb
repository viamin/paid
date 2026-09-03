# frozen_string_literal: true

# Persists why a KnowledgeRun ended in failure so the reason is queryable
# instead of being lost to log retention (#3796). Adds the structured
# `failure_reason` category (e.g. "in_process_providers_failed"), the
# `error_class`/`error_message` for the terminating attempt, and a
# `completed_at` stamp so finished runs are aggregatable over time without
# falling back to `updated_at` (which can drift from unrelated writes).
#
# @spec KNOWLEDGE-011
class AddFailureReasonToKnowledgeRuns < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def up
    return unless table_exists?(:knowledge_runs)

    unless column_exists?(:knowledge_runs, :failure_reason)
      add_column :knowledge_runs, :failure_reason, :string, limit: 100,
        comment: "Structured reason a failed run ended in failure (e.g. " \
                 "'in_process_providers_failed', 'containerized_providers_failed', " \
                 "'no_supported_container_providers'). Nullable on successful runs."
    end

    unless column_exists?(:knowledge_runs, :error_class)
      add_column :knowledge_runs, :error_class, :string, limit: 150,
        comment: "Ruby class name of the terminating error for a failed run, " \
                 "when one was raised (e.g. 'AgentHarness::ProviderError')."
    end

    unless column_exists?(:knowledge_runs, :error_message)
      add_column :knowledge_runs, :error_message, :text,
        comment: "Human-readable message of the terminating error for a failed run."
    end

    unless column_exists?(:knowledge_runs, :completed_at)
      add_column :knowledge_runs, :completed_at, :datetime,
        comment: "When the run finished (completed or failed). Distinct from " \
                 "updated_at, which is touched by unrelated writes."
    end

    if index_exists?(:knowledge_runs, [ :project_id, :status ], name: "index_knowledge_runs_on_project_id_and_status")
      remove_index :knowledge_runs, name: "index_knowledge_runs_on_project_id_and_status", algorithm: :concurrently, if_exists: true
    end

    add_index :knowledge_runs,
      [ :operation_type, :status, :failure_reason ],
      name: "index_knowledge_runs_on_failure_diagnostics",
      if_not_exists: true,
      algorithm: :concurrently

    add_index :knowledge_runs,
      [ :project_id, :status, :completed_at ],
      name: "index_knowledge_runs_on_project_id_and_status",
      if_not_exists: true,
      algorithm: :concurrently
  end

  def down
    return unless table_exists?(:knowledge_runs)

    if index_exists?(:knowledge_runs, [ :project_id, :status, :completed_at ], name: "index_knowledge_runs_on_project_id_and_status")
      remove_index :knowledge_runs, name: "index_knowledge_runs_on_project_id_and_status", algorithm: :concurrently, if_exists: true
    end

    if index_exists?(:knowledge_runs, [ :operation_type, :status, :failure_reason ], name: "index_knowledge_runs_on_failure_diagnostics")
      remove_index :knowledge_runs, name: "index_knowledge_runs_on_failure_diagnostics", algorithm: :concurrently, if_exists: true
    end

    if column_exists?(:knowledge_runs, :completed_at)
      add_index :knowledge_runs, [ :project_id, :status ], name: "index_knowledge_runs_on_project_id_and_status", if_not_exists: true, algorithm: :concurrently
      remove_column :knowledge_runs, :completed_at
    end

    remove_column :knowledge_runs, :error_message if column_exists?(:knowledge_runs, :error_message)
    remove_column :knowledge_runs, :error_class if column_exists?(:knowledge_runs, :error_class)
    remove_column :knowledge_runs, :failure_reason if column_exists?(:knowledge_runs, :failure_reason)
  end
end
