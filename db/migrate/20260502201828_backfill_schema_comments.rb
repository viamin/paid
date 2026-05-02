# frozen_string_literal: true

class BackfillSchemaComments < ActiveRecord::Migration[8.1]
  def change
    comment_table :agent_run_phases,
      "Tracks the discrete lifecycle phases recorded for an agent run so setup, execution, post-processing, and cleanup can be timed and inspected."
    comment_column :agent_run_phases, :phase_key,
      "Specific phase identifier such as create_agent_run, provision_container, run_agent, or create_pull_request."
    comment_column :agent_run_phases, :phase_group,
      "High-level phase bucket: setup, prompt, agent, post, or cleanup."
    comment_column :agent_run_phases, :status,
      "Outcome for the recorded phase. Currently completed or failed."
    comment_column :agent_run_phases, :metadata,
      "Structured phase-specific details captured for debugging or UI display."

    comment_table :agent_run_anomalies,
      "Stores statistical outliers detected when an agent run metric deviates materially from the project's historical baseline."
    comment_column :agent_run_anomalies, :anomaly_type,
      "Direction of the deviation relative to baseline, such as high_value or low_value."
    comment_column :agent_run_anomalies, :severity,
      "Escalation level for the anomaly. Currently warning or critical."
    comment_column :agent_run_anomalies, :metric_name,
      "Baseline-tracked metric that triggered the anomaly, such as duration_seconds or cost_cents."
    comment_column :agent_run_anomalies, :metric_value,
      "Observed value for the anomalous metric on this agent run."
    comment_column :agent_run_anomalies, :baseline_mean,
      "Historical mean for the metric from the project's baseline record."
    comment_column :agent_run_anomalies, :baseline_standard_deviation,
      "Historical standard deviation for the metric from the project's baseline record."
    comment_column :agent_run_anomalies, :deviation_factor,
      "Number of baseline standard deviations between the observed value and the baseline mean."
    comment_column :agent_run_anomalies, :message,
      "Human-readable explanation of why the run was flagged as anomalous."

    comment_table :configuration_experiments,
      "Runs A/B-style experiments on configuration values so Paid can compare rollout variants using downstream quality signals."
    comment_column :configuration_experiments, :account_id,
      "Owning account for account-scoped experiments. Null means the experiment is global."
    comment_column :configuration_experiments, :config_key,
      "Configuration setting under test, such as a prompt or model-related behavior flag."
    comment_column :configuration_experiments, :status,
      "Lifecycle state for the experiment: draft, running, completed, or cancelled."
    comment_column :configuration_experiments, :control_value,
      "Baseline configuration value that treatment variants are compared against."
    comment_column :configuration_experiments, :experiment_type,
      "Kind of signal being optimized, such as agent_output, llm_output, or quality_signal."
    comment_column :configuration_experiments, :min_samples_per_variant,
      "Minimum assignment count required for each variant before analysis is considered reliable."
    comment_column :configuration_experiments, :confidence_threshold,
      "Statistical confidence threshold required before selecting a winning variant."
    comment_column :configuration_experiments, :traffic_percentage,
      "Percentage of eligible traffic routed into the experiment instead of bypassing it."
    comment_column :configuration_experiments, :cached_analysis,
      "Persisted summary of the latest experiment analysis for dashboards and polling."
    comment_column :configuration_experiments, :analysis_samples_key,
      "Cache key derived from assignment counts so stale cached analysis can be detected."
    comment_column :configuration_experiments, :winner_variant_id,
      "Variant selected as the winner when the experiment is completed."

    comment_table :configuration_experiment_variants,
      "Defines the control and treatment values that participate in a configuration experiment."
    comment_column :configuration_experiment_variants, :config_value,
      "Concrete configuration value assigned to traffic for this variant."
    comment_column :configuration_experiment_variants, :is_control,
      "Marks the baseline variant that represents the pre-experiment behavior."
    comment_column :configuration_experiment_variants, :sample_count,
      "Number of agent runs assigned to this variant."
    comment_column :configuration_experiment_variants, :total_quality_score,
      "Sum of quality scores across assignments so averages can be derived incrementally."
    comment_column :configuration_experiment_variants, :avg_quality_score,
      "Average observed quality score for runs assigned to this variant."

    comment_table :configuration_experiment_assignments,
      "Records which experiment variant a specific agent run received so outcomes can be analyzed later."
    comment_column :configuration_experiment_assignments, :quality_score,
      "Observed quality score attributed to the assigned variant for this run."

    comment_table :container_pool_entries,
      "Represents a warm-container pool slot that can be pre-provisioned, claimed by a run, or recycled after failure."
    comment_column :container_pool_entries, :agent_run_id,
      "Agent run that claimed or last used the warm pool entry."
    comment_column :container_pool_entries, :status,
      "Warm pool lifecycle state: warming, warm, claimed, or error."
    comment_column :container_pool_entries, :workspace_volume,
      "Docker volume that preserves the prepared workspace for fast reuse."
    comment_column :container_pool_entries, :warmed_at,
      "Time the container finished warming and became available for claiming."
    comment_column :container_pool_entries, :claimed_at,
      "Time an agent run claimed the warm container entry."
    comment_column :container_pool_entries, :last_error,
      "Most recent provisioning or lifecycle error for this pool entry."

    comment_table :context_intake_sessions,
      "Captures a structured context-gathering interview for a project before or between agent runs."
    comment_column :context_intake_sessions, :status,
      "Session state: in_progress, completed, stale, or archived."
    comment_column :context_intake_sessions, :schema_version,
      "Version of the intake questionnaire schema used to generate the session."
    comment_column :context_intake_sessions, :current_step,
      "Zero-based position within the intake flow so the UI can resume where it left off."
    comment_column :context_intake_sessions, :completed_at,
      "When the intake session was explicitly completed."
    comment_column :context_intake_sessions, :stale_at,
      "When the session was marked stale because its context was no longer current."
    comment_column :context_intake_sessions, :metadata,
      "Structured intake context that does not fit the normalized response rows."

    comment_table :context_intake_responses,
      "Stores individual answers collected during a context intake session, including follow-up questions."
    comment_column :context_intake_responses, :question_key,
      "Stable identifier for the prompt so the same question can be referenced across schema versions."
    comment_column :context_intake_responses, :answer_data,
      "Structured answer payload for non-freeform responses or extracted metadata."
    comment_column :context_intake_responses, :section,
      "Logical intake section used to group related questions in the UI."
    comment_column :context_intake_responses, :sequence,
      "Ordering position within the section."
    comment_column :context_intake_responses, :is_follow_up,
      "Whether this response came from a generated follow-up question instead of the base questionnaire."
    comment_column :context_intake_responses, :parent_response_id,
      "Original response that prompted this follow-up question, when applicable."
    comment_column :context_intake_responses, :skipped,
      "Whether the question was intentionally skipped instead of unanswered."
    comment_column :context_intake_responses, :provenance,
      "Who supplied the answer, currently human or agent."

    comment_table :knowledge_recommendations,
      "Actionable recommendations generated from knowledge-base usage patterns to improve repository context collection."
    comment_column :knowledge_recommendations, :recommendation_type,
      "Recommendation category such as add_collector, remove_collector, improve_collector, or knowledge_gap."
    comment_column :knowledge_recommendations, :collector_type,
      "Collector implicated by the recommendation when the action targets a specific collector."
    comment_column :knowledge_recommendations, :evidence,
      "Structured supporting evidence explaining why the recommendation was generated."
    comment_column :knowledge_recommendations, :status,
      "Recommendation workflow state: pending, accepted, dismissed, or implemented."
    comment_column :knowledge_recommendations, :dismissed_at,
      "When the recommendation was dismissed."
    comment_column :knowledge_recommendations, :dismissal_reason,
      "Reason recorded when a recommendation is dismissed."

    comment_table :knowledge_usage_stats,
      "Aggregates how an agent run consumed retrieved knowledge so search/bundle context effectiveness can be analyzed."
    comment_column :knowledge_usage_stats, :artifact_type,
      "Knowledge artifact category consumed by the run, such as code, docs, or decision records."
    comment_column :knowledge_usage_stats, :goal,
      "Agent run goal associated with the usage record, such as create_pr or review."
    comment_column :knowledge_usage_stats, :context_type,
      "Retrieval mode used to supply context. Currently search or bundle."
    comment_column :knowledge_usage_stats, :artifact_count,
      "Number of distinct artifacts included in the retrieved context."
    comment_column :knowledge_usage_stats, :chunk_count,
      "Number of knowledge chunks included in the retrieved context."
    comment_column :knowledge_usage_stats, :token_count,
      "Approximate token cost of the retrieved knowledge context."
    comment_column :knowledge_usage_stats, :metadata,
      "Additional retrieval details used for reporting or debugging."

    comment_table :project_baselines,
      "Stores per-project historical baselines for run metrics so anomalies can be detected against recent norms."
    comment_column :project_baselines, :metric_name,
      "Tracked agent run metric summarized by this baseline, such as tokens_total, duration_seconds, iterations, or cost_cents."
    comment_column :project_baselines, :mean,
      "Historical mean value for the tracked metric."
    comment_column :project_baselines, :standard_deviation,
      "Historical standard deviation for the tracked metric."
    comment_column :project_baselines, :sample_count,
      "Number of runs contributing to the baseline calculation."
    comment_column :project_baselines, :p95,
      "Ninety-fifth percentile for the tracked metric."
    comment_column :project_baselines, :last_calculated_at,
      "When the baseline values were last recomputed."

    comment_table :quality_gate_thresholds,
      "Defines per-project quality gate rules that trigger pauses or recovery when metrics breach expected bounds."
    comment_column :quality_gate_thresholds, :metric_key,
      "Quality metric evaluated by the gate, such as composite_score, lint_clean, or review_score."
    comment_column :quality_gate_thresholds, :min_threshold,
      "Lower bound whose breach triggers the gate for metrics where too low is bad."
    comment_column :quality_gate_thresholds, :max_threshold,
      "Upper bound whose breach triggers the gate for metrics where too high is bad."
    comment_column :quality_gate_thresholds, :severity,
      "Severity assigned when the gate is breached: info, warning, or critical."
    comment_column :quality_gate_thresholds, :enabled,
      "Whether this threshold currently participates in quality gate evaluation."

    comment_table :quality_gate_events,
      "Records each threshold breach and recovery observed by the quality gate system."
    comment_column :quality_gate_events, :event_type,
      "Quality gate transition being recorded: trigger or recovery."
    comment_column :quality_gate_events, :score_value,
      "Observed metric value that triggered the event."
    comment_column :quality_gate_events, :threshold_value,
      "Specific threshold value that was breached or recovered."
    comment_column :quality_gate_events, :metadata,
      "Structured context about the gate evaluation and follow-up actions."

    comment_table :quality_pause_events,
      "Audit trail for project-level automatic pauses and resumptions caused by quality gate outcomes."
    comment_column :quality_pause_events, :event_type,
      "Pause lifecycle event: paused when automation is halted or resumed when it is re-enabled."
    comment_column :quality_pause_events, :composite_score,
      "Composite quality score observed when the pause or resume decision was made."
    comment_column :quality_pause_events, :threshold,
      "Composite score threshold that justified the pause or resume event."
    comment_column :quality_pause_events, :metadata,
      "Structured context for the pause decision, including contributing signals."

    comment_table :quality_recovery_actions,
      "Tracks remediation steps proposed or executed after a quality gate pause so recovery effectiveness can be measured."
    comment_column :quality_recovery_actions, :action_type,
      "Recovery strategy being attempted, such as prompt_rollback, model_change, or final_pause."
    comment_column :quality_recovery_actions, :status,
      "Execution state for the recovery action: pending, executing, executed, evaluated, or failed."
    comment_column :quality_recovery_actions, :diagnosis,
      "Structured diagnosis explaining why this recovery action was selected."
    comment_column :quality_recovery_actions, :parameters,
      "Inputs required to execute the recovery action."
    comment_column :quality_recovery_actions, :result,
      "Structured output and evaluation details produced by the recovery action."
    comment_column :quality_recovery_actions, :quality_before,
      "Quality score before the recovery action was executed."
    comment_column :quality_recovery_actions, :quality_after,
      "Quality score measured after the recovery action was evaluated."
    comment_column :quality_recovery_actions, :executed_at,
      "When execution of the recovery action began or completed."
    comment_column :quality_recovery_actions, :evaluated_at,
      "When the impact of the recovery action was evaluated."

    comment_table :llm_output_metrics,
      "Stores scored quality signals for specific LLM-generated artifacts so prompt and output quality can be tracked over time."
    comment_column :llm_output_metrics, :output_type,
      "Artifact category being scored, such as pr_description, issue_title, or decision_record."
    comment_column :llm_output_metrics, :prompt_slug,
      "Logical prompt identifier associated with the generated output."
    comment_column :llm_output_metrics, :source_id,
      "Primary key of the application record whose generated output was scored."
    comment_column :llm_output_metrics, :source_type,
      "Application record type referenced by source_id, such as PullRequest, Issue, or DecisionRecord."
    comment_column :llm_output_metrics, :scores,
      "Named metric scores used to evaluate the output before calculating any composite score."
    comment_column :llm_output_metrics, :composite_score,
      "Weighted aggregate quality score derived from the scores payload."
    comment_column :llm_output_metrics, :metadata,
      "Additional scoring context used for reporting or troubleshooting."

    comment_table :tracker_configurations,
      "Stores external issue-tracker integration settings for an account, user, or project."
    comment_column :tracker_configurations, :configurable_type,
      "Polymorphic owner type for the tracker configuration: Account, User, or Project."
    comment_column :tracker_configurations, :configurable_id,
      "Polymorphic owner id for the account, user, or project that owns the tracker configuration."
    comment_column :tracker_configurations, :tracker_type,
      "External tracker implementation, such as github_issues, jira, linear, azure_devops, mcp, or generic_webhook."
    comment_column :tracker_configurations, :base_url,
      "Tracker base URL used when the integration targets a self-hosted or custom endpoint."
    comment_column :tracker_configurations, :integration_credential_id,
      "Credential used to authenticate to the external tracker when one is required."
    comment_column :tracker_configurations, :project_mapping,
      "Mapping data between Paid entities and tracker-specific project identifiers."
    comment_column :tracker_configurations, :enabled,
      "Whether this tracker configuration is active for automation."
    comment_column :tracker_configurations, :created_by_id,
      "User who created the tracker configuration."
  end

  private

  def comment_table(table_name, comment)
    change_table_comment table_name, from: nil, to: comment
  end

  def comment_column(table_name, column_name, comment)
    change_column_comment table_name, column_name, from: nil, to: comment
  end
end
