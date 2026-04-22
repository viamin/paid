# frozen_string_literal: true

class AddPerformanceQueryIndexes < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def change
    add_index :agent_runs, [ :project_id, :created_at ],
      order: { created_at: :desc },
      name: "idx_agent_runs_project_created_at_desc",
      algorithm: :concurrently

    add_index :agent_runs, [ :project_id, :status, :created_at ],
      order: { created_at: :desc },
      name: "idx_agent_runs_project_status_created_at_desc",
      algorithm: :concurrently

    add_index :issues, [ :project_id, :is_pull_request, :pr_review_phase, :github_updated_at ],
      order: { github_updated_at: :desc },
      name: "idx_issues_project_pr_phase_updated_at_desc",
      algorithm: :concurrently

    add_index :knowledge_artifacts, [ :project_id, :status, :identifier ],
      name: "idx_knowledge_artifacts_project_status_identifier",
      algorithm: :concurrently

    add_index :knowledge_chunks, [ :project_id, :status, :knowledge_artifact_id, :sequence ],
      name: "idx_knowledge_chunks_project_status_artifact_sequence",
      algorithm: :concurrently

    add_index :quality_gate_thresholds, [ :project_id, :enabled, :metric_key ],
      name: "idx_quality_gate_thresholds_project_enabled_metric",
      algorithm: :concurrently

    add_index :quality_metrics, [ :prompt_version_id, :created_at ],
      order: { created_at: :desc },
      where: "composite_score IS NOT NULL",
      name: "idx_quality_metrics_prompt_recent_composite",
      algorithm: :concurrently

    add_index :token_usages, [ :request_type, :created_at ],
      name: "idx_token_usages_request_type_created_at",
      algorithm: :concurrently

    add_index :token_usages, [ :agent_run_id, :created_at ],
      name: "idx_token_usages_agent_run_created_at",
      algorithm: :concurrently

    add_index :token_usages, [ :knowledge_run_id, :created_at ],
      name: "idx_token_usages_knowledge_run_created_at",
      algorithm: :concurrently
  end
end
