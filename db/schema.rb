# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.1].define(version: 2026_08_01_142109) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "hstore"
  enable_extension "pg_catalog.plpgsql"
  enable_extension "pg_trgm"

  create_table "ab_test_assignments", force: :cascade do |t|
    t.bigint "ab_test_id", null: false
    t.bigint "ab_test_variant_id", null: false
    t.bigint "agent_run_id", null: false
    t.datetime "created_at", null: false
    t.decimal "quality_score", precision: 5, scale: 4
    t.datetime "updated_at", null: false
    t.index ["ab_test_id", "agent_run_id"], name: "index_ab_test_assignments_unique", unique: true
    t.index ["ab_test_id"], name: "index_ab_test_assignments_on_ab_test_id"
    t.index ["ab_test_variant_id"], name: "index_ab_test_assignments_on_ab_test_variant_id"
    t.index ["agent_run_id"], name: "index_ab_test_assignments_on_agent_run_id"
  end

  create_table "ab_test_variants", force: :cascade do |t|
    t.bigint "ab_test_id", null: false
    t.decimal "avg_quality_score", precision: 5, scale: 4
    t.datetime "created_at", null: false
    t.boolean "is_control", default: false, null: false
    t.bigint "prompt_version_id", null: false
    t.integer "sample_count", default: 0, null: false
    t.decimal "total_quality_score", precision: 10, scale: 4, default: "0.0", null: false
    t.datetime "updated_at", null: false
    t.index ["ab_test_id", "is_control"], name: "index_ab_test_variants_on_test_and_control"
    t.index ["ab_test_id", "prompt_version_id"], name: "index_ab_test_variants_on_test_and_prompt_version", unique: true
    t.index ["ab_test_id"], name: "index_ab_test_variants_on_ab_test_id"
    t.index ["ab_test_id"], name: "index_ab_test_variants_on_control_per_test", unique: true, where: "(is_control = true)"
    t.index ["prompt_version_id"], name: "index_ab_test_variants_on_prompt_version_id"
  end

  create_table "ab_tests", force: :cascade do |t|
    t.string "analysis_samples_key"
    t.jsonb "cached_analysis"
    t.datetime "completed_at"
    t.decimal "confidence_threshold", precision: 5, scale: 4, default: "0.95", null: false
    t.bigint "control_version_id", null: false
    t.datetime "created_at", null: false
    t.text "description"
    t.string "idempotency_key"
    t.integer "min_samples_per_variant", default: 30, null: false
    t.string "name", limit: 255, null: false
    t.bigint "prompt_id", null: false
    t.datetime "started_at"
    t.string "status", limit: 50, default: "draft", null: false
    t.datetime "updated_at", null: false
    t.bigint "winner_variant_id"
    t.index ["control_version_id"], name: "index_ab_tests_on_control_version_id"
    t.index ["prompt_id", "idempotency_key"], name: "index_ab_tests_on_prompt_and_idempotency_key", unique: true, where: "(idempotency_key IS NOT NULL)"
    t.index ["prompt_id", "status"], name: "index_ab_tests_on_prompt_id_and_status"
    t.index ["prompt_id"], name: "index_ab_tests_on_prompt_id"
    t.index ["prompt_id"], name: "index_ab_tests_one_running_per_prompt", unique: true, where: "((status)::text = 'running'::text)"
    t.index ["status"], name: "index_ab_tests_on_status"
    t.index ["winner_variant_id"], name: "index_ab_tests_on_winner_variant_id"
  end

  create_table "account_activity_events", force: :cascade do |t|
    t.bigint "account_id", null: false, comment: "Account whose administration history this event belongs to."
    t.string "action", null: false, comment: "Stable action key for the account administration event."
    t.bigint "actor_id", comment: "User who performed the action, when available."
    t.datetime "created_at", null: false
    t.jsonb "metadata", default: {}, null: false, comment: "Structured event details for UI rendering and audits."
    t.bigint "subject_id"
    t.string "subject_type", comment: "Polymorphic subject type affected by the action."
    t.datetime "updated_at", null: false
    t.index ["account_id", "created_at"], name: "index_account_activity_events_on_account_id_and_created_at"
    t.index ["actor_id"], name: "index_account_activity_events_on_actor_id"
    t.index ["subject_type", "subject_id"], name: "index_account_activity_events_on_subject_type_and_subject_id"
  end

  create_table "account_memberships", force: :cascade do |t|
    t.bigint "account_id", null: false
    t.datetime "created_at", null: false
    t.jsonb "log_data"
    t.integer "role", default: 0, null: false
    t.datetime "updated_at", null: false
    t.bigint "user_id", null: false
    t.index ["account_id", "role"], name: "index_account_memberships_on_account_id_and_role"
    t.index ["account_id"], name: "index_account_memberships_on_account_id"
    t.index ["user_id", "account_id"], name: "index_account_memberships_on_user_id_and_account_id", unique: true
    t.index ["user_id"], name: "index_account_memberships_on_user_id"
  end

  create_table "accounts", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.datetime "deactivated_at"
    t.integer "default_max_tokens_per_run", default: 10000000, null: false
    t.jsonb "log_data"
    t.string "name", null: false
    t.datetime "onboarding_completed_at"
    t.string "plan", default: "trial", null: false
    t.jsonb "remediation_policy", default: {}, null: false, comment: "Per-action self-heal remediation modes and thresholds for this account."
    t.datetime "scheduler_paused_at"
    t.string "slug", null: false
    t.integer "status", default: 0, null: false
    t.datetime "suspended_at"
    t.datetime "trial_ends_at"
    t.datetime "updated_at", null: false
    t.index ["slug"], name: "index_accounts_on_slug", unique: true
    t.index ["status"], name: "index_accounts_on_status"
  end

  create_table "agent_coordination_signals", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "parent_workflow_id", limit: 255, null: false
    t.jsonb "payload", default: {}, null: false
    t.string "signal_type", limit: 50, null: false
    t.bigint "source_agent_run_id", null: false
    t.bigint "target_agent_run_id"
    t.index ["parent_workflow_id", "signal_type"], name: "idx_coordination_signals_workflow_type"
    t.index ["parent_workflow_id"], name: "index_agent_coordination_signals_on_parent_workflow_id"
    t.index ["source_agent_run_id"], name: "index_agent_coordination_signals_on_source_agent_run_id"
    t.index ["target_agent_run_id", "signal_type"], name: "idx_coordination_signals_target_type"
    t.index ["target_agent_run_id"], name: "index_agent_coordination_signals_on_target_agent_run_id"
  end

  create_table "agent_run_anomalies", comment: "Stores statistical outliers detected when an agent run metric deviates materially from the project's historical baseline.", force: :cascade do |t|
    t.bigint "agent_run_id", null: false
    t.string "anomaly_type", limit: 50, null: false, comment: "Direction of the deviation relative to baseline, such as high_value or low_value."
    t.float "baseline_mean", null: false, comment: "Historical mean for the metric from the project's baseline record."
    t.float "baseline_standard_deviation", null: false, comment: "Historical standard deviation for the metric from the project's baseline record."
    t.datetime "created_at", null: false
    t.float "deviation_factor", null: false, comment: "Number of baseline standard deviations between the observed value and the baseline mean."
    t.text "message", comment: "Human-readable explanation of why the run was flagged as anomalous."
    t.string "metric_name", limit: 50, null: false, comment: "Baseline-tracked metric that triggered the anomaly, such as duration_seconds or cost_cents."
    t.float "metric_value", null: false, comment: "Observed value for the anomalous metric on this agent run."
    t.bigint "project_id", null: false
    t.string "severity", limit: 20, null: false, comment: "Escalation level for the anomaly. Currently warning or critical."
    t.datetime "updated_at", null: false
    t.index ["agent_run_id", "metric_name"], name: "index_agent_run_anomalies_on_agent_run_id_and_metric_name", unique: true
    t.index ["agent_run_id"], name: "index_agent_run_anomalies_on_agent_run_id"
    t.index ["anomaly_type"], name: "index_agent_run_anomalies_on_anomaly_type"
    t.index ["project_id", "created_at"], name: "index_agent_run_anomalies_on_project_id_and_created_at"
    t.index ["project_id"], name: "index_agent_run_anomalies_on_project_id"
  end

  create_table "agent_run_logs", force: :cascade do |t|
    t.bigint "agent_run_id", null: false
    t.text "content", null: false
    t.datetime "created_at", null: false
    t.string "log_type", limit: 50, null: false
    t.jsonb "metadata"
    t.index ["agent_run_id", "log_type"], name: "index_agent_run_logs_on_agent_run_id_and_log_type"
    t.index ["agent_run_id"], name: "index_agent_run_logs_on_agent_run_id"
    t.index ["created_at"], name: "index_agent_run_logs_on_created_at"
  end

  create_table "agent_run_marketplace_entries", comment: "Marketplace entries attached to a specific agent run with rendered provider payloads", force: :cascade do |t|
    t.bigint "agent_run_id", null: false
    t.string "attachment_source", limit: 50, null: false, comment: "Whether the attachment came from manual selection, a team default, or automatic matching."
    t.datetime "created_at", null: false
    t.bigint "marketplace_entry_id", null: false
    t.bigint "marketplace_entry_version_id", null: false
    t.integer "position", default: 0, null: false
    t.string "rendered_format", limit: 100, default: "canonical_v1", null: false, comment: "Exact provider-facing format emitted for this run."
    t.jsonb "rendered_payload", default: {}, null: false, comment: "Resolved provider-facing payload snapshot used by this run."
    t.text "selection_reason"
    t.datetime "updated_at", null: false
    t.index ["agent_run_id", "attachment_source", "position"], name: "index_agent_run_marketplace_entries_on_run_source_position"
    t.index ["agent_run_id", "marketplace_entry_id"], name: "index_agent_run_marketplace_entries_unique_attachment", unique: true
    t.index ["agent_run_id"], name: "index_agent_run_marketplace_entries_on_agent_run_id"
    t.index ["marketplace_entry_id"], name: "index_agent_run_marketplace_entries_on_marketplace_entry_id"
    t.index ["marketplace_entry_version_id"], name: "idx_arm_entries_entry_ver"
  end

  create_table "agent_run_phases", comment: "Tracks the discrete lifecycle phases recorded for an agent run so setup, execution, post-processing, and cleanup can be timed and inspected.", force: :cascade do |t|
    t.bigint "agent_run_id", null: false
    t.datetime "created_at", null: false
    t.integer "duration_seconds", default: 0, null: false
    t.datetime "finished_at", null: false
    t.jsonb "metadata", default: {}, null: false, comment: "Structured phase-specific details captured for debugging or UI display."
    t.string "phase_group", limit: 50, null: false, comment: "High-level phase bucket: setup, prompt, agent, post, or cleanup."
    t.string "phase_key", limit: 100, null: false, comment: "Specific phase identifier such as create_agent_run, provision_container, run_agent, or create_pull_request."
    t.datetime "started_at", null: false
    t.string "status", limit: 50, default: "completed", null: false, comment: "Outcome for the recorded phase. Currently completed or failed."
    t.datetime "updated_at", null: false
    t.index ["agent_run_id", "started_at"], name: "index_agent_run_phases_on_agent_run_id_and_started_at"
    t.index ["agent_run_id"], name: "index_agent_run_phases_on_agent_run_id"
    t.index ["phase_group", "started_at"], name: "index_agent_run_phases_on_phase_group_and_started_at"
    t.index ["phase_key", "started_at"], name: "index_agent_run_phases_on_phase_key_and_started_at"
    t.check_constraint "duration_seconds >= 0", name: "agent_run_phases_duration_seconds_non_negative"
    t.check_constraint "finished_at >= started_at", name: "agent_run_phases_finished_at_after_started_at"
  end

  create_table "agent_run_resource_profiles", comment: "Learned memory usage rollups for agent runs across exact and fallback scopes.", force: :cascade do |t|
    t.bigint "account_id", comment: "Owning account for account/project-scoped profiles."
    t.boolean "capacity_blocked", default: false, null: false, comment: "True when the profile has hit the configured memory ceiling while still OOM-killing runs. Further limit growth is paused until Docker capacity or the ceiling increases."
    t.datetime "capacity_blocked_at", comment: "When the profile first transitioned into capacity_blocked. Nil while the profile remains unblocked."
    t.integer "consecutive_low_memory_samples", default: 0, null: false, comment: "Counter of consecutive successful samples where observed peak stayed well below the recommended limit. Required before any downward tuning, to prevent oscillation."
    t.datetime "created_at", null: false
    t.integer "downward_tuning_count", default: 0, null: false, comment: "Total number of times the profile has been downward-tuned. Useful for debugging anti-oscillation behavior."
    t.string "goal", comment: "Agent goal for runner-scoped profiles."
    t.datetime "last_oom_at", comment: "Timestamp of the most recent sampled OOM event."
    t.string "lookup_key", null: false, comment: "Deterministic unique key for one profile scope row."
    t.bigint "max_memory_bytes", default: 0, null: false, comment: "Maximum observed peak memory across sampled runs."
    t.integer "oom_count", default: 0, null: false, comment: "Number of sampled runs that showed container OOM evidence."
    t.bigint "p50_memory_bytes", default: 0, null: false, comment: "Median observed peak memory across sampled runs."
    t.bigint "p95_memory_bytes", default: 0, null: false, comment: "95th percentile observed peak memory across sampled runs."
    t.string "profile_level", null: false, comment: "Profile scope: specific, runner_goal, project, account, or global."
    t.bigint "project_id", comment: "Project for exact or project-level profiles."
    t.bigint "recommended_memory_limit_bytes", default: 0, null: false, comment: "Learned memory limit recommendation derived from observed peaks and OOMs."
    t.string "runner_key", comment: "Normalized runner key for runner-scoped profiles."
    t.integer "sample_count", default: 0, null: false, comment: "Number of terminal runs contributing a memory sample."
    t.datetime "updated_at", null: false
    t.index ["account_id"], name: "index_agent_run_resource_profiles_on_account_id"
    t.index ["lookup_key"], name: "index_agent_run_resource_profiles_on_lookup_key", unique: true
    t.index ["profile_level", "sample_count"], name: "idx_on_profile_level_sample_count_92a9d20505"
    t.index ["project_id"], name: "index_agent_run_resource_profiles_on_project_id"
    t.index ["runner_key", "goal"], name: "index_agent_run_resource_profiles_on_runner_key_and_goal", where: "((runner_key IS NOT NULL) AND (goal IS NOT NULL))"
  end

  create_table "agent_runs", force: :cascade do |t|
    t.string "adoption_mode_snapshot", comment: "Project adoption mode captured when an external execution was ingested."
    t.string "agent_type", limit: 50, null: false
    t.string "auth_provider", limit: 50
    t.boolean "auto_pick", default: false, null: false
    t.float "avg_cpu_percent"
    t.decimal "avg_memory_bytes", precision: 20, scale: 4
    t.string "base_commit_sha", limit: 40
    t.bigint "blocked_by_issue_ids", default: [], comment: "IDs of issues/PRs that block the created issue from being picked up for work.", array: true
    t.string "branch_name", limit: 255
    t.datetime "completed_at"
    t.bigint "configuration_bundle_id", comment: "Configuration bundle assigned to the run before execution."
    t.string "configuration_bundle_selection_context", comment: "Primary optimization context used for bundle routing, such as task or project."
    t.string "configuration_bundle_selection_mode", comment: "Whether configuration bundle routing favored exploitative or exploratory selection for this run."
    t.string "container_host", limit: 64, default: "local", comment: "Container backend host identifier used to provision and reconnect to this run's container."
    t.string "container_id", limit: 128
    t.integer "container_metrics_count", default: 0, null: false
    t.datetime "container_retained_until"
    t.integer "cost_cents", default: 0
    t.boolean "count_toward_draft_review_round", default: false, null: false
    t.datetime "created_at", null: false
    t.integer "created_issue_number"
    t.string "created_issue_url", limit: 500
    t.jsonb "cross_repo_issues", default: []
    t.text "custom_prompt"
    t.string "diagnosis_issue_url", limit: 500
    t.string "diagnosis_status", limit: 50
    t.integer "duration_seconds"
    t.text "error_message"
    t.string "execution_origin", default: "paid_native", null: false, comment: "Whether the run executed inside Paid or was ingested from an external toolchain."
    t.integer "expected_draft_review_count"
    t.jsonb "external_metadata", default: {}, null: false, comment: "Structured metadata captured from external execution and migration workflows."
    t.string "external_run_key", comment: "Stable external run identifier used for idempotent ingestion."
    t.string "external_source_key", comment: "External system that executed the run, such as github_copilot, cursor, devin, factory, or internal_agent_workflows."
    t.string "final_runner", limit: 50
    t.string "focus", limit: 50, default: "general", null: false, comment: "Focused run intent derived from the highest-priority PR trigger or assigned workflow context."
    t.boolean "git_credential_fallback_active", default: false, null: false, comment: "Transient flag set by Containers::GitOperations only while retrying a push with the project's git_push_fallback_token PAT. The git-credentials proxy serves the fallback PAT (instead of the App installation token) while this is true, then it is cleared. Not part of run history/state."
    t.string "goal", limit: 50, default: "create_pr", null: false
    t.jsonb "guardrail_context"
    t.string "guardrail_violation_type", limit: 50
    t.bigint "initiating_user_id", comment: "User who explicitly initiated the run; null for system-triggered runs."
    t.bigint "issue_id"
    t.integer "iterations", default: 0
    t.jsonb "mcp_provisioned_servers", default: {}, null: false, comment: "Materialized MCP server specs (stdio_servers + url_servers) produced by provisioning"
    t.jsonb "mcp_server_snapshot", default: [], null: false
    t.jsonb "mcp_sidecar_container_ids", default: [], null: false, comment: "Docker container IDs of MCP sidecar containers provisioned for this run"
    t.string "parent_workflow_id", limit: 255
    t.datetime "paused_at"
    t.float "peak_cpu_percent"
    t.bigint "peak_memory_bytes"
    t.string "plan_doc_source", limit: 1000, comment: "User-named plan document (RDR/ADR/design doc path or URL) the lid_planning run treats as authored intent. Only set for lid_planning runs."
    t.string "priority_tier", limit: 10
    t.bigint "project_id", null: false
    t.bigint "prompt_version_id"
    t.string "proxy_token", limit: 64
    t.integer "pull_request_number"
    t.string "pull_request_url", limit: 500
    t.datetime "queue_entered_at", comment: "Most recent time this run entered queued status so queue latency metrics reflect the current queue episode."
    t.datetime "rate_limited_until"
    t.string "result_commit_sha", limit: 40
    t.datetime "review_posted_at"
    t.jsonb "review_proxy_diagnostics", default: {}, null: false, comment: "Latest known outcome of the review-creation proxy POST for this run (outcome: attempted/timeout/connection_failed/upstream_error/succeeded, plus http_status/error_class/error_message/recorded_at when available). Lets CompleteReviewGoalActivity explain review-goal failures without raw log inspection (#2779). Not part of run history/state."
    t.string "review_url", limit: 500
    t.bigint "runner_id"
    t.integer "runner_switches", default: 0, null: false
    t.jsonb "runners_attempted", default: [], null: false
    t.jsonb "screenshot_hints", default: {}, null: false, comment: "Per-route screenshot hints derived from the agent's change (route name => {summary, selector}). Used to scope and annotate UI screenshots to what the agent actually changed."
    t.jsonb "service_container_ids", default: []
    t.jsonb "service_environment", default: {}
    t.integer "source_pull_request_number"
    t.integer "stale_requeue_count", default: 0, null: false
    t.integer "stale_skip_count", default: 0, null: false
    t.datetime "started_at"
    t.string "status", limit: 50, default: "queued", null: false
    t.jsonb "streaming_turns_data", default: [], null: false, comment: "Per-turn metrics from streaming JSONL events (turn number, tokens, duration)"
    t.string "temporal_run_id", limit: 255
    t.string "temporal_workflow_id", limit: 255
    t.string "token_limit_status", limit: 50
    t.integer "tokens_input", default: 0
    t.integer "tokens_output", default: 0
    t.string "trigger_type", limit: 50, default: "automatic", null: false
    t.integer "turns_completed", default: 0, null: false, comment: "Number of agent turns completed, tracked via streaming JSONL progress events"
    t.datetime "updated_at", null: false
    t.string "worktree_path", limit: 500
    t.index ["configuration_bundle_id"], name: "index_agent_runs_on_configuration_bundle_id"
    t.index ["created_at"], name: "index_agent_runs_on_created_at"
    t.index ["execution_origin"], name: "index_agent_runs_on_execution_origin"
    t.index ["focus"], name: "index_agent_runs_on_focus"
    t.index ["guardrail_violation_type"], name: "index_agent_runs_on_guardrail_violation_type", where: "(guardrail_violation_type IS NOT NULL)"
    t.index ["initiating_user_id"], name: "index_agent_runs_on_initiating_user_id"
    t.index ["issue_id"], name: "index_agent_runs_on_issue_id"
    t.index ["parent_workflow_id"], name: "index_agent_runs_on_parent_workflow_id"
    t.index ["project_id", "created_at"], name: "idx_agent_runs_project_created_at_desc", order: { created_at: :desc }
    t.index ["project_id", "external_source_key", "external_run_key"], name: "idx_agent_runs_external_dedup", unique: true, where: "(external_run_key IS NOT NULL)"
    t.index ["project_id", "goal"], name: "index_agent_runs_on_project_id_and_goal"
    t.index ["project_id", "issue_id", "goal"], name: "idx_agent_runs_unique_active_issue", unique: true, where: "((issue_id IS NOT NULL) AND ((status)::text = ANY (ARRAY[('queued'::character varying)::text, ('pending'::character varying)::text, ('running'::character varying)::text, ('paused'::character varying)::text])))"
    t.index ["project_id", "source_pull_request_number", "goal"], name: "idx_agent_runs_unique_active_pr", unique: true, where: "((source_pull_request_number IS NOT NULL) AND ((status)::text = ANY (ARRAY[('queued'::character varying)::text, ('pending'::character varying)::text, ('running'::character varying)::text, ('paused'::character varying)::text])))"
    t.index ["project_id", "source_pull_request_number", "status"], name: "idx_agent_runs_review_feedback_lookup"
    t.index ["project_id", "status", "completed_at"], name: "index_agent_runs_on_project_status_completed_at"
    t.index ["project_id", "status", "created_at"], name: "idx_agent_runs_project_status_created_at_desc", order: { created_at: :desc }
    t.index ["project_id", "status"], name: "index_agent_runs_on_project_id_and_status"
    t.index ["project_id"], name: "idx_agent_runs_unique_active_lid_planning", unique: true, where: "(((goal)::text = 'lid_planning'::text) AND ((status)::text = ANY ((ARRAY['queued'::character varying, 'rate_limited'::character varying, 'running'::character varying, 'paused'::character varying])::text[])))"
    t.index ["project_id"], name: "index_agent_runs_on_project_id"
    t.index ["prompt_version_id"], name: "index_agent_runs_on_prompt_version_id"
    t.index ["proxy_token"], name: "index_agent_runs_on_proxy_token", unique: true
    t.index ["runner_id"], name: "index_agent_runs_on_runner_id"
    t.index ["status"], name: "index_agent_runs_on_status"
    t.index ["temporal_workflow_id"], name: "index_agent_runs_on_temporal_workflow_id"
  end

  create_table "billing_invoices", force: :cascade do |t|
    t.bigint "account_id", null: false
    t.bigint "billing_period_id", null: false
    t.datetime "created_at", null: false
    t.datetime "due_at"
    t.string "external_id", limit: 255
    t.datetime "issued_at"
    t.jsonb "log_data"
    t.jsonb "metadata", default: {}, null: false
    t.datetime "paid_at"
    t.string "status", limit: 20, default: "draft", null: false
    t.integer "subtotal_cents", default: 0, null: false
    t.integer "tax_cents", default: 0, null: false
    t.integer "total_cents", default: 0, null: false
    t.datetime "updated_at", null: false
    t.index ["account_id", "status"], name: "index_billing_invoices_on_account_id_and_status"
    t.index ["account_id"], name: "index_billing_invoices_on_account_id"
    t.index ["billing_period_id"], name: "index_billing_invoices_on_billing_period_id"
    t.index ["external_id"], name: "index_billing_invoices_on_external_id", unique: true, where: "(external_id IS NOT NULL)"
  end

  create_table "billing_line_items", force: :cascade do |t|
    t.bigint "billing_invoice_id", null: false
    t.datetime "created_at", null: false
    t.string "description", null: false
    t.string "line_item_type", limit: 30, null: false
    t.jsonb "metadata", default: {}, null: false
    t.decimal "quantity", precision: 18, scale: 4, default: "0.0", null: false
    t.integer "total_cents", default: 0, null: false
    t.integer "unit_price_cents", default: 0, null: false
    t.datetime "updated_at", null: false
    t.index ["billing_invoice_id"], name: "index_billing_line_items_on_billing_invoice_id"
    t.index ["line_item_type"], name: "index_billing_line_items_on_line_item_type"
  end

  create_table "billing_periods", force: :cascade do |t|
    t.bigint "account_id", null: false
    t.bigint "billing_plan_id", null: false
    t.datetime "created_at", null: false
    t.datetime "ends_at", null: false
    t.jsonb "metadata", default: {}, null: false
    t.string "period_type", limit: 20, null: false
    t.datetime "starts_at", null: false
    t.string "status", limit: 20, default: "open", null: false
    t.integer "total_compute_seconds", default: 0, null: false
    t.integer "total_cost_cents", default: 0, null: false
    t.bigint "total_input_tokens", default: 0, null: false
    t.bigint "total_output_tokens", default: 0, null: false
    t.integer "total_runs", default: 0, null: false
    t.datetime "updated_at", null: false
    t.index ["account_id", "starts_at", "ends_at"], name: "index_billing_periods_on_account_id_and_starts_at_and_ends_at"
    t.index ["account_id", "status"], name: "index_billing_periods_on_account_id_and_status"
    t.index ["account_id"], name: "index_billing_periods_on_account_id"
    t.index ["billing_plan_id"], name: "index_billing_periods_on_billing_plan_id"
  end

  create_table "billing_plans", force: :cascade do |t|
    t.bigint "account_id", null: false
    t.boolean "active", default: true, null: false
    t.integer "base_rate_cents", default: 0, null: false
    t.string "billing_model", limit: 30, null: false
    t.datetime "created_at", null: false
    t.integer "included_projects", default: 0, null: false
    t.integer "included_runs", default: 0, null: false
    t.bigint "included_tokens", default: 0, null: false
    t.jsonb "log_data"
    t.jsonb "metadata", default: {}, null: false
    t.string "name", limit: 100, null: false
    t.integer "per_project_rate_cents", default: 0, null: false
    t.integer "per_run_rate_cents", default: 0, null: false
    t.decimal "per_token_rate_cents", precision: 12, scale: 6, default: "0.0", null: false
    t.string "period_type", limit: 20, null: false
    t.datetime "updated_at", null: false
    t.index ["account_id", "active"], name: "index_billing_plans_on_account_id_and_active"
    t.index ["account_id"], name: "index_billing_plans_on_account_id"
  end

  create_table "bundle_outcomes", comment: "Measured results from using a configuration bundle on an agent run", force: :cascade do |t|
    t.bigint "agent_run_id", null: false
    t.bigint "configuration_bundle_id", null: false
    t.integer "cost_cents", comment: "Total cost of the agent run in cents"
    t.datetime "created_at", null: false
    t.integer "duration_seconds", comment: "Wall-clock time for the agent run"
    t.jsonb "metrics", default: {}, null: false, comment: "Additional outcome metrics (lines changed, test pass rate, etc.)"
    t.decimal "quality_score", precision: 5, scale: 4, comment: "Overall quality score (0.0-1.0)"
    t.boolean "success", default: false, null: false, comment: "Whether the agent run completed successfully"
    t.integer "tokens_used", comment: "Total tokens (input + output) consumed"
    t.datetime "updated_at", null: false
    t.index ["agent_run_id"], name: "index_bundle_outcomes_on_agent_run_id"
    t.index ["configuration_bundle_id", "agent_run_id"], name: "index_bundle_outcomes_unique_run", unique: true
    t.index ["quality_score"], name: "index_bundle_outcomes_on_quality_score"
    t.index ["success"], name: "index_bundle_outcomes_on_success"
  end

  create_table "change_intents", comment: "Captures human directional intent that should persist in the knowledge base.", force: :cascade do |t|
    t.text "behavior", comment: "Expected behavior, often captured as given/when/then scenarios."
    t.bigint "chat_session_id", comment: "Chat session where the intent was captured, when applicable."
    t.text "constraints", comment: "Boundaries and constraints that shaped the implementation."
    t.datetime "created_at", null: false
    t.text "decisions_made", comment: "Alternatives that were rejected and why."
    t.text "intent", null: false, comment: "What the human was trying to accomplish."
    t.bigint "issue_id", comment: "Issue that motivated or contextualized the intent, when applicable."
    t.bigint "project_id", null: false, comment: "Project this change intent applies to."
    t.string "status", limit: 50, default: "draft", null: false, comment: "Lifecycle state for the record: draft, active, or superseded."
    t.bigint "superseded_by_id", comment: "Newer change intent that superseded this record."
    t.text "title", null: false, comment: "Short title summarizing the intent."
    t.datetime "updated_at", null: false
    t.index ["chat_session_id"], name: "index_change_intents_on_chat_session_id"
    t.index ["issue_id"], name: "index_change_intents_on_issue_id"
    t.index ["project_id", "status"], name: "index_change_intents_on_project_id_and_status"
    t.index ["project_id"], name: "index_change_intents_on_project_id"
    t.index ["superseded_by_id"], name: "index_change_intents_on_superseded_by_id"
  end

  create_table "chat_messages", force: :cascade do |t|
    t.bigint "chat_session_id", null: false
    t.text "content"
    t.datetime "created_at", null: false
    t.uuid "external_id", default: -> { "gen_random_uuid()" }, null: false
    t.jsonb "metadata", default: {}
    t.string "model"
    t.string "role", null: false
    t.integer "tokens_input"
    t.integer "tokens_output"
    t.jsonb "tool_arguments"
    t.string "tool_call_id"
    t.string "tool_name"
    t.jsonb "tool_result"
    t.string "tool_status", comment: "Confirmation state for write tool calls: pending, approved, or denied"
    t.datetime "updated_at", null: false
    t.index ["chat_session_id", "created_at"], name: "index_chat_messages_on_chat_session_id_and_created_at"
    t.index ["chat_session_id"], name: "index_chat_messages_on_chat_session_id"
    t.index ["external_id"], name: "index_chat_messages_on_external_id", unique: true
    t.index ["role"], name: "index_chat_messages_on_role"
    t.index ["tool_status"], name: "index_chat_messages_on_tool_status", where: "((tool_status)::text = 'pending'::text)"
  end

  create_table "chat_session_projects", force: :cascade do |t|
    t.bigint "chat_session_id", null: false
    t.string "context_type", default: "reference", null: false
    t.datetime "created_at", null: false
    t.bigint "project_id", null: false
    t.datetime "updated_at", null: false
    t.index ["chat_session_id", "project_id"], name: "index_chat_session_projects_on_chat_session_id_and_project_id", unique: true
    t.index ["chat_session_id"], name: "index_chat_session_projects_on_chat_session_id"
    t.index ["project_id"], name: "index_chat_session_projects_on_project_id"
  end

  create_table "chat_sessions", force: :cascade do |t|
    t.bigint "account_id", null: false
    t.boolean "auto_approve", default: false, null: false, comment: "When true, write tool calls (e.g. agent run creation) are auto-approved without a manual confirmation click"
    t.jsonb "clone_manifest", default: [], null: false, comment: "Persisted clone metadata used to reopen a reaped multi-repo chat workspace."
    t.string "container_capability", default: "none", null: false, comment: "Container capability lifecycle for the chat session: none, pending, provisioning, ready, failed, or stopped."
    t.string "container_id"
    t.datetime "container_ready_at", comment: "When the session's container-backed workspace most recently became ready."
    t.datetime "container_requested_at", comment: "When the session most recently requested a container-backed workspace."
    t.datetime "created_at", null: false
    t.bigint "created_by_id"
    t.uuid "external_id", default: -> { "gen_random_uuid()" }, null: false
    t.datetime "idle_timeout_at"
    t.jsonb "metadata", default: {}
    t.string "model"
    t.bigint "project_id"
    t.string "proxy_token", limit: 64
    t.bigint "runner_id"
    t.string "status", default: "active", null: false
    t.text "system_prompt"
    t.string "title"
    t.datetime "updated_at", null: false
    t.string "workspace_volume"
    t.index ["account_id"], name: "index_chat_sessions_on_account_id"
    t.index ["created_by_id"], name: "index_chat_sessions_on_created_by_id"
    t.index ["external_id"], name: "index_chat_sessions_on_external_id", unique: true
    t.index ["idle_timeout_at"], name: "index_chat_sessions_on_idle_timeout_at"
    t.index ["project_id"], name: "index_chat_sessions_on_project_id"
    t.index ["proxy_token"], name: "index_chat_sessions_on_proxy_token", unique: true
    t.index ["runner_id"], name: "index_chat_sessions_on_runner_id"
    t.index ["status"], name: "index_chat_sessions_on_status"
  end

  create_table "claude_login_sessions", force: :cascade do |t|
    t.bigint "account_id", null: false, comment: "Account that owns this browser-completed Claude login session."
    t.datetime "completed_at"
    t.string "container_id"
    t.datetime "created_at", null: false
    t.bigint "created_by_id", null: false, comment: "User who initiated the Claude browser login."
    t.string "credential_name", null: false, comment: "IntegrationCredential name to create or replace on successful capture."
    t.text "error_message"
    t.datetime "expires_at", comment: "Session expiry until completed; replaced with credential expiry after capture."
    t.uuid "external_id", null: false, comment: "Opaque public identifier used in user-facing URLs."
    t.datetime "failed_at"
    t.bigint "integration_credential_id", comment: "Managed Claude credential captured when the login completes."
    t.jsonb "metadata", default: {}, null: false, comment: "Structured runtime details such as return paths and parsed Claude metadata."
    t.text "oauth_url"
    t.bigint "runner_credential_id", comment: "Managed Claude runner credential captured when the browser login completes."
    t.string "session_token", null: false, comment: "Time-boxed shared secret required to submit the browser code."
    t.string "status", default: "starting", null: false, comment: "Browser login lifecycle state."
    t.datetime "submitted_at"
    t.datetime "updated_at", null: false
    t.index ["account_id"], name: "index_claude_login_sessions_on_account_id"
    t.index ["created_by_id"], name: "index_claude_login_sessions_on_created_by_id"
    t.index ["external_id"], name: "index_claude_login_sessions_on_external_id", unique: true
    t.index ["integration_credential_id"], name: "index_claude_login_sessions_on_integration_credential_id"
    t.index ["runner_credential_id"], name: "index_claude_login_sessions_on_runner_credential_id"
    t.index ["session_token"], name: "index_claude_login_sessions_on_session_token", unique: true
  end

  create_table "codex_login_sessions", comment: "Device-code Connect Codex login sessions (RDR-041 / #2962).", force: :cascade do |t|
    t.bigint "account_id", null: false, comment: "Account that owns this Connect Codex login session."
    t.datetime "completed_at"
    t.datetime "created_at", null: false
    t.bigint "created_by_id", null: false, comment: "User who initiated the Connect Codex login."
    t.string "credential_name", null: false, comment: "RunnerCredential name to create or replace on successful capture."
    t.text "device_code", comment: "Encrypted device_code used to poll the OAuth token endpoint."
    t.text "error_message"
    t.datetime "expires_at", comment: "Device-code expiry; replaced with credential expiry after capture."
    t.uuid "external_id", null: false, comment: "Opaque public identifier used in user-facing URLs."
    t.datetime "failed_at"
    t.jsonb "metadata", default: {}, null: false, comment: "Structured runtime details such as return paths and parsed Codex metadata."
    t.integer "poll_interval", comment: "Seconds between token-endpoint polls."
    t.bigint "runner_credential_id", comment: "Managed Codex credential captured when the login completes."
    t.string "session_token", null: false, comment: "Time-boxed shared secret required to advance the device-code poll."
    t.string "status", default: "starting", null: false, comment: "Device-code login lifecycle state."
    t.datetime "updated_at", null: false
    t.string "user_code", comment: "Short code the user enters at the verification URI."
    t.text "verification_uri", comment: "URI the user visits to authorize the device."
    t.index ["account_id"], name: "index_codex_login_sessions_on_account_id"
    t.index ["created_by_id"], name: "index_codex_login_sessions_on_created_by_id"
    t.index ["external_id"], name: "index_codex_login_sessions_on_external_id", unique: true
    t.index ["runner_credential_id"], name: "index_codex_login_sessions_on_runner_credential_id"
    t.index ["session_token"], name: "index_codex_login_sessions_on_session_token", unique: true
  end

  create_table "collector_runs", force: :cascade do |t|
    t.integer "artifacts_count", default: 0
    t.string "collector_type", limit: 100, null: false
    t.datetime "completed_at"
    t.datetime "created_at", null: false
    t.integer "duration_ms"
    t.text "error_message"
    t.jsonb "metadata", default: {}
    t.bigint "project_version_id", null: false
    t.datetime "started_at"
    t.string "status", limit: 50, default: "pending", null: false
    t.string "tool_version", limit: 100
    t.datetime "updated_at", null: false
    t.index ["project_version_id", "collector_type"], name: "index_collector_runs_on_project_version_id_and_collector_type", unique: true
    t.index ["project_version_id"], name: "index_collector_runs_on_project_version_id"
    t.index ["status"], name: "index_collector_runs_on_status"
  end

  create_table "configuration_bundles", comment: "Versioned snapshots of configuration components used for agent runs", force: :cascade do |t|
    t.bigint "account_id", null: false
    t.datetime "activated_at", comment: "When the bundle was promoted to active"
    t.jsonb "context", default: {}, null: false, comment: "Additional context such as guardrails, token budgets, or feature flags"
    t.datetime "created_at", null: false
    t.jsonb "definition", default: {}, null: false, comment: "Canonical runtime configuration snapshot used for optimization and fingerprinting"
    t.text "description"
    t.string "fingerprint", limit: 64, comment: "Content-addressable hash for deduplication"
    t.bigint "llm_model_id", comment: "The LLM model included in this bundle"
    t.jsonb "log_data"
    t.string "name", limit: 255, null: false
    t.bigint "project_id", comment: "Optional project scope; NULL means account-wide bundle"
    t.bigint "prompt_version_id", comment: "The prompt template version included in this bundle"
    t.datetime "retired_at", comment: "When the bundle was retired"
    t.string "status", limit: 50, default: "draft", null: false, comment: "Lifecycle state: draft, active, retired"
    t.string "strategy", limit: 100, comment: "Orchestration strategy identifier (e.g. single_agent, multi_agent)"
    t.jsonb "strategy_params", default: {}, null: false, comment: "Strategy-specific parameters (concurrency, escalation thresholds, etc.)"
    t.datetime "updated_at", null: false
    t.integer "version", default: 1, null: false, comment: "Monotonic version number within the account/project scope"
    t.index ["account_id", "fingerprint"], name: "index_config_bundles_unique_fingerprint", unique: true, where: "(fingerprint IS NOT NULL)"
    t.index ["account_id", "project_id", "version"], name: "index_config_bundles_unique_version_project", unique: true, where: "(project_id IS NOT NULL)"
    t.index ["account_id", "status"], name: "index_config_bundles_on_account_status"
    t.index ["account_id", "version"], name: "index_config_bundles_unique_version_account", unique: true, where: "(project_id IS NULL)"
    t.index ["account_id"], name: "index_configuration_bundles_on_account_id"
    t.index ["llm_model_id"], name: "index_configuration_bundles_on_llm_model_id"
    t.index ["project_id", "status"], name: "index_config_bundles_on_project_status"
    t.index ["project_id"], name: "index_configuration_bundles_on_project_id"
    t.index ["prompt_version_id"], name: "index_configuration_bundles_on_prompt_version_id"
    t.index ["status"], name: "index_configuration_bundles_on_status"
  end

  create_table "configuration_experiment_assignments", comment: "Records which experiment variant a specific agent run received so outcomes can be analyzed later.", force: :cascade do |t|
    t.bigint "agent_run_id", null: false
    t.bigint "configuration_experiment_id", null: false
    t.bigint "configuration_experiment_variant_id", null: false
    t.datetime "created_at", null: false
    t.decimal "quality_score", precision: 5, scale: 4, comment: "Observed quality score attributed to the assigned variant for this run."
    t.datetime "updated_at", null: false
    t.index ["agent_run_id"], name: "index_configuration_experiment_assignments_on_agent_run_id"
    t.index ["configuration_experiment_id", "agent_run_id"], name: "index_config_experiment_assignments_unique", unique: true
    t.index ["configuration_experiment_id"], name: "idx_on_configuration_experiment_id_6532d1a5ed"
    t.index ["configuration_experiment_variant_id"], name: "idx_on_configuration_experiment_variant_id_9de5ff7df6"
  end

  create_table "configuration_experiment_variants", comment: "Defines the control and treatment values that participate in a configuration experiment.", force: :cascade do |t|
    t.decimal "avg_quality_score", precision: 5, scale: 4, comment: "Average observed quality score for runs assigned to this variant."
    t.text "config_value", null: false, comment: "Concrete configuration value assigned to traffic for this variant."
    t.bigint "configuration_experiment_id", null: false
    t.datetime "created_at", null: false
    t.boolean "is_control", default: false, null: false, comment: "Marks the baseline variant that represents the pre-experiment behavior."
    t.integer "sample_count", default: 0, null: false, comment: "Number of agent runs assigned to this variant."
    t.decimal "total_quality_score", precision: 10, scale: 4, default: "0.0", null: false, comment: "Sum of quality scores across assignments so averages can be derived incrementally."
    t.datetime "updated_at", null: false
    t.index ["configuration_experiment_id", "is_control"], name: "index_config_experiment_variants_on_experiment_and_control"
    t.index ["configuration_experiment_id"], name: "idx_on_configuration_experiment_id_54cb3ed654"
    t.index ["configuration_experiment_id"], name: "index_config_experiment_variants_one_control", unique: true, where: "(is_control = true)"
  end

  create_table "configuration_experiments", comment: "Runs A/B-style experiments on configuration values so Paid can compare rollout variants using downstream quality signals.", force: :cascade do |t|
    t.bigint "account_id", comment: "Owning account for account-scoped experiments. Null means the experiment is global."
    t.string "analysis_samples_key", comment: "Cache key derived from assignment counts so stale cached analysis can be detected."
    t.jsonb "cached_analysis", comment: "Persisted summary of the latest experiment analysis for dashboards and polling."
    t.datetime "completed_at"
    t.decimal "confidence_threshold", precision: 5, scale: 4, default: "0.95", null: false, comment: "Statistical confidence threshold required before selecting a winning variant."
    t.string "config_key", null: false, comment: "Configuration setting under test, such as a prompt or model-related behavior flag."
    t.text "control_value", null: false, comment: "Baseline configuration value that treatment variants are compared against."
    t.datetime "created_at", null: false
    t.text "description"
    t.string "experiment_type", limit: 50, null: false, comment: "Kind of signal being optimized, such as agent_output, llm_output, or quality_signal."
    t.integer "min_samples_per_variant", default: 30, null: false, comment: "Minimum assignment count required for each variant before analysis is considered reliable."
    t.string "name", null: false
    t.datetime "started_at"
    t.string "status", limit: 50, default: "draft", null: false, comment: "Lifecycle state for the experiment: draft, running, completed, or cancelled."
    t.integer "traffic_percentage", default: 100, null: false, comment: "Percentage of eligible traffic routed into the experiment instead of bypassing it."
    t.datetime "updated_at", null: false
    t.bigint "winner_variant_id", comment: "Variant selected as the winner when the experiment is completed."
    t.index ["account_id", "config_key", "status"], name: "idx_on_account_id_config_key_status_a42f39cd2a"
    t.index ["account_id", "config_key"], name: "index_config_experiments_one_running_per_account_key", unique: true, where: "(((status)::text = 'running'::text) AND (account_id IS NOT NULL))"
    t.index ["account_id"], name: "index_configuration_experiments_on_account_id"
    t.index ["config_key"], name: "index_global_config_experiments_one_running_per_key", unique: true, where: "(((status)::text = 'running'::text) AND (account_id IS NULL))"
    t.index ["winner_variant_id"], name: "index_configuration_experiments_on_winner_variant_id"
  end

  create_table "container_metrics", force: :cascade do |t|
    t.bigint "agent_run_id", null: false
    t.string "container_id", limit: 128, null: false
    t.float "cpu_percent", default: 0.0, null: false
    t.datetime "created_at", null: false
    t.bigint "memory_bytes", default: 0, null: false
    t.bigint "memory_limit_bytes", default: 0, null: false
    t.float "memory_percent", default: 0.0, null: false
    t.integer "pids_count"
    t.datetime "recorded_at", null: false
    t.datetime "updated_at", null: false
    t.index ["agent_run_id", "recorded_at"], name: "index_container_metrics_on_run_and_recorded"
    t.index ["container_id"], name: "index_container_metrics_on_container_id"
    t.index ["recorded_at"], name: "index_container_metrics_on_recorded_at"
  end

  create_table "container_pool_entries", comment: "Represents a warm-container pool slot that can be pre-provisioned, claimed by a run, or recycled after failure.", force: :cascade do |t|
    t.bigint "agent_run_id", comment: "Agent run that claimed or last used the warm pool entry."
    t.datetime "claimed_at", precision: nil, comment: "Time an agent run claimed the warm container entry."
    t.string "container_host", limit: 64, default: "local", comment: "Container backend host identifier for the warmed container."
    t.string "container_id", limit: 128
    t.datetime "created_at", null: false
    t.string "image", null: false
    t.text "last_error", comment: "Most recent provisioning or lifecycle error for this pool entry."
    t.string "network", limit: 64, null: false
    t.bigint "project_id", null: false
    t.string "status", limit: 20, null: false, comment: "Warm pool lifecycle state: warming, warm, claimed, or error."
    t.datetime "updated_at", null: false
    t.datetime "warmed_at", precision: nil, comment: "Time the container finished warming and became available for claiming."
    t.string "workspace_volume", limit: 128, null: false, comment: "Docker volume that preserves the prepared workspace for fast reuse."
    t.index ["agent_run_id"], name: "index_container_pool_entries_on_agent_run_id"
    t.index ["container_id"], name: "index_container_pool_entries_on_container_id", unique: true, where: "(container_id IS NOT NULL)"
    t.index ["project_id", "container_host", "status"], name: "idx_pool_entries_project_host_status"
    t.index ["project_id", "status", "warmed_at"], name: "idx_on_project_id_status_warmed_at_d791387888"
    t.index ["project_id"], name: "index_container_pool_entries_on_project_id"
    t.index ["workspace_volume"], name: "index_container_pool_entries_on_workspace_volume", unique: true
  end

  create_table "context_intake_questions", comment: "Catalog of data-driven business-context wizard questions, including authored and AI-generated follow-ups.", force: :cascade do |t|
    t.boolean "active", default: true, null: false, comment: "Whether this question is eligible to appear in the wizard."
    t.string "category", limit: 100, null: false, comment: "Semantic category for reporting and future branching logic."
    t.jsonb "conditions", default: {}, null: false, comment: "Branching conditions that determine when the question should be shown."
    t.datetime "created_at", null: false
    t.integer "display_order", default: 0, null: false, comment: "Question ordering within its section and round."
    t.boolean "is_follow_up", default: false, null: false, comment: "Marks questions that refine or extend prior answers."
    t.string "key", limit: 200, null: false, comment: "Stable question key used to match answers and link follow-up relationships."
    t.jsonb "metadata", default: {}, null: false, comment: "Additional extensible metadata that should evolve without schema churn."
    t.string "parent_question_key", limit: 200, comment: "Optional source question key this follow-up is refining."
    t.bigint "project_id", comment: "Project-specific question ownership. Null means a shared default catalog question."
    t.string "provenance", limit: 50, default: "human", null: false, comment: "Whether the question was authored manually or generated by an agent."
    t.text "question_text", null: false, comment: "Prompt text presented to the maintainer in the business-context wizard."
    t.boolean "required", default: false, null: false, comment: "Whether the question must be answered before completing the session."
    t.integer "round", default: 1, null: false, comment: "Question round. Round 1 is the base questionnaire; later rounds are follow-ups."
    t.string "section_key", limit: 100, null: false, comment: "Logical section identifier used for grouping and knowledge synthesis."
    t.integer "section_order", default: 0, null: false, comment: "Section ordering within a round."
    t.string "section_title", limit: 200, null: false, comment: "Human-readable section heading shown in the wizard."
    t.string "status", limit: 50, default: "approved", null: false, comment: "Review state for this question definition."
    t.datetime "updated_at", null: false
    t.jsonb "validation_rules", default: {}, null: false, comment: "Extensible validation metadata for future answer schemas."
    t.index ["key"], name: "idx_context_intake_questions_global_key_unique", unique: true, where: "(project_id IS NULL)"
    t.index ["project_id", "active", "status"], name: "idx_context_intake_questions_visibility"
    t.index ["project_id", "key"], name: "idx_context_intake_questions_project_key", unique: true
    t.index ["project_id", "parent_question_key"], name: "idx_context_intake_questions_parent"
    t.index ["project_id", "round", "section_order"], name: "idx_context_intake_questions_round_order"
    t.index ["project_id"], name: "index_context_intake_questions_on_project_id"
  end

  create_table "context_intake_responses", comment: "Stores individual answers collected during a context intake session, including follow-up questions.", force: :cascade do |t|
    t.jsonb "answer_data", default: {}, comment: "Structured answer payload for non-freeform responses or extracted metadata."
    t.text "answer_text"
    t.bigint "context_intake_session_id", null: false
    t.datetime "created_at", null: false
    t.boolean "is_follow_up", default: false, comment: "Whether this response came from a generated follow-up question instead of the base questionnaire."
    t.bigint "parent_response_id", comment: "Original response that prompted this follow-up question, when applicable."
    t.string "provenance", limit: 50, default: "human", comment: "Who supplied the answer, currently human or agent."
    t.string "question_key", limit: 200, null: false, comment: "Stable identifier for the prompt so the same question can be referenced across schema versions."
    t.text "question_text", null: false
    t.string "section", limit: 100, null: false, comment: "Logical intake section used to group related questions in the UI."
    t.integer "sequence", default: 0, null: false, comment: "Ordering position within the section."
    t.boolean "skipped", default: false, comment: "Whether the question was intentionally skipped instead of unanswered."
    t.datetime "updated_at", null: false
    t.index ["context_intake_session_id", "question_key"], name: "idx_context_intake_responses_session_question", unique: true
    t.index ["context_intake_session_id", "section", "sequence"], name: "idx_context_intake_responses_session_section_seq"
    t.index ["context_intake_session_id"], name: "index_context_intake_responses_on_context_intake_session_id"
    t.index ["parent_response_id"], name: "index_context_intake_responses_on_parent_response_id"
  end

  create_table "context_intake_sessions", comment: "Captures a structured context-gathering interview for a project before or between agent runs.", force: :cascade do |t|
    t.datetime "completed_at", comment: "When the intake session was explicitly completed."
    t.datetime "created_at", null: false
    t.integer "current_step", default: 0, comment: "Zero-based position within the intake flow so the UI can resume where it left off."
    t.jsonb "metadata", default: {}, comment: "Structured intake context that does not fit the normalized response rows."
    t.bigint "project_id", null: false
    t.string "schema_version", limit: 20, default: "1.0", null: false, comment: "Version of the intake questionnaire schema used to generate the session."
    t.datetime "stale_at", comment: "When the session was marked stale because its context was no longer current."
    t.bigint "started_by_id", null: false
    t.string "status", limit: 50, default: "in_progress", null: false, comment: "Session state: in_progress, completed, stale, or archived."
    t.datetime "updated_at", null: false
    t.index ["project_id", "created_at"], name: "index_context_intake_sessions_on_project_id_and_created_at", order: { created_at: :desc }
    t.index ["project_id", "status"], name: "index_context_intake_sessions_on_project_id_and_status"
    t.index ["project_id"], name: "index_context_intake_sessions_on_project_id"
    t.index ["started_by_id"], name: "index_context_intake_sessions_on_started_by_id"
  end

  create_table "coordination_experiment_assignments", comment: "Assignment and outcome for one feature orchestration workflow sample", force: :cascade do |t|
    t.bigint "coordination_experiment_id", null: false
    t.bigint "coordination_experiment_variant_id", null: false
    t.decimal "coordination_score", precision: 5, scale: 4
    t.datetime "created_at", null: false
    t.bigint "issue_id"
    t.jsonb "outcome_metrics", default: {}, null: false, comment: "Aggregated coordination quality and cost metrics"
    t.string "outcome_status", default: "assigned", null: false
    t.bigint "project_id", null: false
    t.datetime "updated_at", null: false
    t.string "workflow_id", null: false, comment: "Temporal workflow ID for the orchestrated feature sample"
    t.index ["coordination_experiment_id", "workflow_id"], name: "idx_coordination_experiment_assignments_unique", unique: true
    t.index ["coordination_experiment_id"], name: "idx_on_coordination_experiment_id_73eaaefa30"
    t.index ["coordination_experiment_variant_id"], name: "idx_on_coordination_experiment_variant_id_d60101236e"
    t.index ["issue_id"], name: "index_coordination_experiment_assignments_on_issue_id"
    t.index ["project_id"], name: "index_coordination_experiment_assignments_on_project_id"
  end

  create_table "coordination_experiment_variants", comment: "Individual policy arms within a coordination experiment", force: :cascade do |t|
    t.decimal "avg_coordination_score", precision: 5, scale: 4
    t.bigint "coordination_experiment_id", null: false
    t.datetime "created_at", null: false
    t.boolean "is_control", default: false, null: false
    t.jsonb "policy_config", default: {}, null: false, comment: "Effective policy config for this variant"
    t.integer "sample_count", default: 0, null: false
    t.decimal "total_coordination_score", precision: 10, scale: 4, default: "0.0", null: false
    t.datetime "updated_at", null: false
    t.index ["coordination_experiment_id", "is_control"], name: "idx_coordination_experiment_variants_one_control", unique: true, where: "(is_control = true)"
    t.index ["coordination_experiment_id"], name: "idx_on_coordination_experiment_id_3f1ff8497b"
  end

  create_table "coordination_experiments", comment: "Workflow-scoped A/B tests for feature orchestration coordination policies", force: :cascade do |t|
    t.bigint "account_id", null: false
    t.datetime "completed_at"
    t.jsonb "control_policy", default: {}, null: false, comment: "Baseline coordination policy configuration"
    t.datetime "created_at", null: false
    t.text "description"
    t.integer "min_samples_per_variant", default: 10, null: false
    t.string "name", null: false
    t.string "policy_name", default: "feature_orchestration", null: false, comment: "Coordination policy family under test"
    t.datetime "started_at"
    t.string "status", default: "draft", null: false
    t.integer "traffic_percentage", default: 100, null: false
    t.datetime "updated_at", null: false
    t.bigint "winner_variant_id"
    t.index ["account_id", "policy_name", "status"], name: "idx_coordination_experiments_account_policy_status"
    t.index ["account_id", "policy_name"], name: "idx_coordination_experiments_one_running_policy", unique: true, where: "((status)::text = 'running'::text)"
    t.index ["account_id"], name: "index_coordination_experiments_on_account_id"
    t.index ["winner_variant_id"], name: "index_coordination_experiments_on_winner_variant_id"
  end

  create_table "coordination_policies", comment: "Versioned coordination policy catalogs that drive decomposition, recovery, escalation, and lifecycle decisions.", force: :cascade do |t|
    t.bigint "account_id", null: false, comment: "Tenant that owns this policy family."
    t.jsonb "context_selector", default: {}, null: false, comment: "Structured selector used to decide when this policy applies."
    t.datetime "created_at", null: false
    t.bigint "current_version_id"
    t.text "description", comment: "Long-form summary of what this policy is intended to optimize or protect."
    t.jsonb "metadata", default: {}, null: false, comment: "Additional structured provenance, rollout, and audit details."
    t.string "name", null: false, comment: "Human-readable policy name shown in admin and experiment tooling."
    t.string "policy_key", limit: 100, null: false, comment: "Stable identifier used by runtime policy selection."
    t.string "policy_type", limit: 50, null: false, comment: "Decision domain controlled by this policy: decomposition, recovery, escalation, or lifecycle_state."
    t.bigint "project_id", comment: "Optional project-specific override; nil means account-wide default."
    t.string "status", limit: 30, default: "draft", null: false, comment: "Catalog lifecycle state: draft, active, or archived."
    t.datetime "updated_at", null: false
    t.index ["account_id", "policy_type", "policy_key"], name: "idx_coordination_policies_account_scope_key", unique: true, where: "(project_id IS NULL)"
    t.index ["account_id", "policy_type", "status"], name: "idx_coordination_policies_account_type_status"
    t.index ["account_id", "project_id", "policy_type", "policy_key"], name: "idx_coordination_policies_project_scope_key", unique: true, where: "(project_id IS NOT NULL)"
    t.index ["account_id"], name: "index_coordination_policies_on_account_id"
    t.index ["current_version_id"], name: "index_coordination_policies_on_current_version_id"
    t.index ["project_id", "policy_type", "status"], name: "idx_coordination_policies_project_type_status"
    t.index ["project_id"], name: "index_coordination_policies_on_project_id"
  end

  create_table "coordination_policy_versions", comment: "Immutable policy revisions that carry the executable rules and tunable parameters for a coordination policy.", force: :cascade do |t|
    t.datetime "activated_at", comment: "When this version became the policy's active revision."
    t.bigint "coordination_policy_id", null: false, comment: "Owning policy catalog entry."
    t.datetime "created_at", null: false
    t.string "idempotency_key"
    t.text "llm_prompt", comment: "Optional prompt template used when the policy delegates part of the decision to an LLM."
    t.jsonb "metadata", default: {}, null: false, comment: "Structured provenance such as generator metadata, rollout notes, and approval state."
    t.jsonb "parameters", default: {}, null: false, comment: "Thresholds, weights, and other tunable policy parameters."
    t.text "reasoning", comment: "Why this policy version exists and what changed from the prior version."
    t.datetime "retired_at", comment: "When this version stopped being eligible for runtime selection."
    t.jsonb "rules", default: {}, null: false, comment: "Structured decision rules executed by coordination services."
    t.string "status", limit: 30, default: "draft", null: false, comment: "Revision lifecycle state: draft, active, superseded, or retired."
    t.datetime "updated_at", null: false
    t.integer "version", null: false, comment: "Monotonic version number within the owning coordination policy."
    t.index ["coordination_policy_id", "idempotency_key"], name: "index_coordination_policy_versions_on_idempotency_key", unique: true, where: "(idempotency_key IS NOT NULL)"
    t.index ["coordination_policy_id", "status", "created_at"], name: "idx_coordination_policy_versions_policy_status_created"
    t.index ["coordination_policy_id", "version"], name: "idx_coordination_policy_versions_unique_version", unique: true
    t.index ["coordination_policy_id"], name: "idx_coordination_policy_versions_one_active", unique: true, where: "((status)::text = 'active'::text)"
    t.index ["coordination_policy_id"], name: "index_coordination_policy_versions_on_coordination_policy_id"
  end

  create_table "cost_budgets", force: :cascade do |t|
    t.datetime "alert_sent_at"
    t.integer "alert_threshold_percent", default: 80, null: false
    t.string "budget_type", limit: 50, null: false
    t.datetime "created_at", null: false
    t.integer "current_usage_cents", default: 0, null: false
    t.string "enforcement_mode", limit: 20, default: "alert", null: false
    t.integer "grace_buffer_percent", default: 0, null: false
    t.integer "limit_cents", null: false
    t.jsonb "log_data"
    t.datetime "period_started_at"
    t.bigint "project_id", null: false
    t.datetime "updated_at", null: false
    t.index ["project_id", "budget_type"], name: "index_cost_budgets_on_project_id_and_budget_type", unique: true
  end

  create_table "decision_record_links", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "decision_record_id", null: false
    t.string "link_type", limit: 50, null: false
    t.string "linkable_id", limit: 100, null: false
    t.string "linkable_type", limit: 100, null: false
    t.index ["decision_record_id", "linkable_type", "linkable_id", "link_type"], name: "index_decision_record_links_on_record_and_linkable_and_type", unique: true
    t.index ["decision_record_id"], name: "index_decision_record_links_on_decision_record_id"
    t.index ["linkable_type", "linkable_id"], name: "index_decision_record_links_on_linkable_type_and_linkable_id"
  end

  create_table "decision_records", force: :cascade do |t|
    t.bigint "agent_run_id"
    t.string "commit_sha_end", limit: 40
    t.string "commit_sha_start", limit: 40
    t.text "consequences"
    t.text "context"
    t.datetime "created_at", null: false
    t.text "decision", null: false
    t.bigint "issue_id"
    t.bigint "project_id", null: false
    t.string "status", limit: 50, default: "draft", null: false
    t.text "summary", null: false
    t.bigint "superseded_by_id"
    t.jsonb "tags", default: [], null: false
    t.string "title", limit: 500, null: false
    t.datetime "updated_at", null: false
    t.index ["agent_run_id"], name: "index_decision_records_on_agent_run_id", unique: true, where: "(agent_run_id IS NOT NULL)"
    t.index ["issue_id"], name: "index_decision_records_on_issue_id"
    t.index ["project_id", "status"], name: "index_decision_records_on_project_id_and_status"
    t.index ["project_id"], name: "index_decision_records_on_project_id"
    t.index ["superseded_by_id"], name: "index_decision_records_on_superseded_by_id"
    t.index ["tags"], name: "index_decision_records_on_tags", using: :gin
  end

  create_table "decomposition_decisions", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "decision_key", null: false, comment: "Idempotency key for this workflow decision boundary."
    t.string "decision_type", null: false, comment: "Decision boundary being recorded, such as planning_outcome or parallelization_outcome."
    t.jsonb "error_details", default: {}, null: false, comment: "Failure details when the decision path ended exceptionally."
    t.jsonb "hints", default: {}, null: false, comment: "Derived dependency and parallelism hints for later analysis."
    t.jsonb "input_context", default: {}, null: false, comment: "Issue and planning inputs available when the decision was made."
    t.bigint "issue_id", null: false, comment: "Parent issue being decomposed or parallelized."
    t.jsonb "metadata", default: {}, null: false, comment: "Additional workflow metadata such as prompt source and activity boundaries."
    t.string "outcome", null: false, comment: "Observed outcome at the decision boundary."
    t.jsonb "plan_data", default: {}, null: false, comment: "Generated tasks, created issues, and related plan artifacts."
    t.bigint "project_id", null: false, comment: "Project whose issue decomposition flow produced this decision."
    t.datetime "updated_at", null: false
    t.string "workflow_id", null: false, comment: "Temporal workflow identifier for correlation across activities."
    t.string "workflow_name", null: false, comment: "Temporal workflow class that emitted the decision."
    t.index ["decision_key"], name: "index_decomposition_decisions_on_decision_key", unique: true
    t.index ["issue_id", "created_at"], name: "index_decomposition_decisions_on_issue_id_and_created_at"
    t.index ["issue_id"], name: "index_decomposition_decisions_on_issue_id"
    t.index ["project_id", "created_at"], name: "index_decomposition_decisions_on_project_id_and_created_at"
    t.index ["project_id"], name: "index_decomposition_decisions_on_project_id"
    t.index ["workflow_id", "decision_type"], name: "index_decomposition_decisions_on_workflow_id_and_decision_type"
  end

  create_table "dispatch_circuit_breakers", comment: "Account-level dispatch circuit breaker that halts scheduling when all providers fail simultaneously", force: :cascade do |t|
    t.bigint "account_id", null: false, comment: "Account this circuit breaker belongs to"
    t.datetime "circuit_opened_at", comment: "When the circuit was last opened"
    t.string "circuit_state", limit: 20, default: "closed", null: false, comment: "Current circuit state: closed, open, or half_open"
    t.datetime "created_at", null: false
    t.integer "half_open_failure_count", default: 0, null: false, comment: "Consecutive failures in half_open state"
    t.integer "half_open_success_count", default: 0, null: false, comment: "Consecutive successes in half_open state"
    t.datetime "last_evaluated_at", comment: "When the circuit was last evaluated"
    t.datetime "last_probe_at", comment: "When the last probe run was dispatched during half_open"
    t.bigint "last_probe_run_id", comment: "Agent run dispatched as the half_open probe; only this run's outcome counts toward the breaker's half_open counters so stale in-flight runs from before the circuit opened cannot close or re-open the breaker"
    t.jsonb "trip_metadata", default: {}, null: false, comment: "Failure statistics at the time the circuit was tripped"
    t.datetime "updated_at", null: false
    t.index ["account_id"], name: "index_dispatch_circuit_breakers_on_account_id", unique: true
  end

  create_table "docker_hosts", comment: "Persisted Docker backend targets and readiness metadata for account-level run placement.", force: :cascade do |t|
    t.bigint "account_id", null: false, comment: "Account that owns and may place runs onto this Docker host."
    t.string "backend_type", null: false, comment: "Docker backend type, such as local, remote, or swarm."
    t.string "callback_url", comment: "Paid proxy callback URL that containers on this host must reach."
    t.text "client_ca_key_pem", comment: "Encrypted CA private key PEM retained when Paid must generate a matching remote Docker server certificate."
    t.text "client_ca_pem", comment: "Encrypted CA certificate PEM used by Paid when connecting to this remote Docker daemon over TLS."
    t.text "client_certificate_pem", comment: "Encrypted client certificate PEM used by Paid when connecting to this remote Docker daemon over TLS."
    t.text "client_private_key_pem", comment: "Encrypted client private key PEM used by Paid when connecting to this remote Docker daemon over TLS."
    t.datetime "created_at", null: false
    t.string "daemon_architecture", comment: "Docker daemon architecture reported by readiness checks."
    t.string "daemon_summary", comment: "Short Docker daemon summary surfaced to operators."
    t.datetime "disabled_at", comment: "When the host was disabled for new placements while retaining historical ownership."
    t.string "display_name", null: false, comment: "Operator-facing label shown in the account admin UI."
    t.boolean "enabled", default: true, null: false, comment: "Whether new manual or automatic placements may target this host."
    t.string "endpoint", comment: "Docker daemon endpoint for remote hosts; blank for the local host."
    t.string "failing_check", comment: "Named readiness check currently failing, if any."
    t.boolean "fallback_eligible", default: true, null: false, comment: "Whether first-healthy fallback may use this host when the preferred host is unavailable."
    t.string "identifier", null: false, comment: "Stable host identifier persisted onto agent_runs.container_host for historical ownership."
    t.string "image_status", default: "unknown", null: false, comment: "Whether the required agent image is present and compatible."
    t.string "image_tag", default: "paid-agent:latest", null: false, comment: "Expected agent image tag for readiness checks and setup guidance."
    t.datetime "last_checked_at", comment: "Most recent readiness probe time."
    t.text "last_error", comment: "Last readiness or provisioning error surfaced to operators."
    t.datetime "last_ready_at", comment: "Most recent successful readiness probe time."
    t.jsonb "log_data"
    t.integer "manual_concurrency_limit", default: 1, null: false, comment: "Independent host-level run cap enforced separately from account, user, and project guardrails."
    t.jsonb "metadata", default: {}, null: false, comment: "Extensible host-scoped readiness and setup metadata."
    t.string "readiness_status", default: "unknown", null: false, comment: "Cached host readiness state shown in the admin control plane."
    t.string "required_network_name", comment: "Docker network name the remote host must provide for disposable agent containers."
    t.string "required_network_status", default: "unknown", null: false, comment: "Whether the required Docker network exists on the host."
    t.text "server_certificate_pem", comment: "Encrypted server certificate PEM generated or uploaded for operator installation on the remote Docker daemon host."
    t.text "server_csr_pem", comment: "Encrypted server certificate signing request PEM generated for operator submission to their certificate authority."
    t.text "server_private_key_pem", comment: "Encrypted server private key PEM generated for manual installation on the remote Docker daemon host."
    t.datetime "updated_at", null: false
    t.index ["account_id", "enabled"], name: "index_docker_hosts_on_account_id_and_enabled"
    t.index ["account_id", "fallback_eligible"], name: "index_docker_hosts_on_account_id_and_fallback_eligible"
    t.index ["account_id", "identifier"], name: "index_docker_hosts_on_account_id_and_identifier", unique: true
    t.index ["account_id"], name: "index_docker_hosts_on_account_id"
  end

  create_table "exception_incidents", force: :cascade do |t|
    t.bigint "account_id", null: false
    t.string "action_taken", default: "logged", null: false
    t.text "backtrace"
    t.jsonb "context", default: {}, null: false
    t.datetime "created_at", null: false
    t.string "exception_class", null: false
    t.string "fingerprint", null: false
    t.integer "github_issue_number"
    t.string "github_issue_url"
    t.datetime "last_occurred_at", null: false
    t.jsonb "log_data"
    t.text "message", null: false
    t.integer "occurrence_count", default: 1, null: false
    t.bigint "project_id"
    t.datetime "resolved_at"
    t.string "severity", default: "p2", null: false
    t.string "status", default: "open", null: false
    t.string "subsystem", null: false
    t.datetime "updated_at", null: false
    t.index ["account_id", "fingerprint"], name: "index_exception_incidents_on_dedup", unique: true
    t.index ["account_id", "status"], name: "index_exception_incidents_on_status"
    t.index ["account_id", "subsystem"], name: "index_exception_incidents_on_subsystem"
    t.index ["project_id"], name: "index_exception_incidents_on_project"
    t.index ["severity"], name: "index_exception_incidents_on_severity"
  end

  create_table "external_connector_events", comment: "Events ingested from external connectors (Jira, Linear, Slack, etc.) for coexistence workflows.", force: :cascade do |t|
    t.bigint "account_id", null: false, comment: "Account this connector event belongs to."
    t.string "connector_key", null: false, comment: "Connector source key from Interop::Catalog (e.g. jira, linear, slack)."
    t.datetime "created_at", null: false
    t.string "event_type", null: false, comment: "Connector-specific event type (e.g. issue_created, pipeline_completed, message_posted)."
    t.string "external_event_id", null: false, comment: "Unique event ID from the external system, used for deduplication."
    t.jsonb "normalized_data", default: {}, comment: "Normalized data extracted from the payload for query and comparison."
    t.datetime "occurred_at", comment: "Timestamp when the event occurred in the external system."
    t.jsonb "payload", default: {}, null: false, comment: "Raw event payload from the external system."
    t.datetime "processed_at", comment: "Timestamp when the event was processed by Paid."
    t.bigint "project_id", null: false, comment: "Project this connector event belongs to."
    t.string "status", default: "pending", null: false, comment: "Processing status: pending, processed, failed."
    t.datetime "updated_at", null: false
    t.index ["account_id", "connector_key"], name: "idx_connector_events_account_connector"
    t.index ["account_id"], name: "index_external_connector_events_on_account_id"
    t.index ["occurred_at"], name: "idx_connector_events_occurred_at"
    t.index ["project_id", "connector_key", "event_type"], name: "idx_connector_events_project_connector_type"
    t.index ["project_id", "connector_key", "external_event_id"], name: "idx_connector_events_project_external_id", unique: true
    t.index ["project_id"], name: "index_external_connector_events_on_project_id"
    t.index ["status", "created_at"], name: "idx_connector_events_status_created"
  end

  create_table "failure_classifications", comment: "Persisted failure classification and chosen recovery action for coordination learning", force: :cascade do |t|
    t.jsonb "action_params", default: {}, null: false, comment: "Parameters passed to the chosen recovery action"
    t.jsonb "action_result", default: {}, null: false, comment: "Outcome of executing the recovery action"
    t.string "action_status", limit: 30, default: "pending", null: false, comment: "Lifecycle: pending, executing, completed, skipped"
    t.bigint "agent_run_id", null: false
    t.string "chosen_action", limit: 50, null: false, comment: "Recovery action selected from coordination policy"
    t.datetime "completed_at"
    t.datetime "created_at", null: false
    t.datetime "executed_at"
    t.string "failure_category", limit: 50, null: false, comment: "Classified failure type (e.g. provider_error, timeout, auth_failure)"
    t.jsonb "failure_context", default: {}, null: false, comment: "Structured details about the failure (error message, provider, etc.)"
    t.string "failure_subcategory", limit: 100, comment: "Optional finer-grained classification"
    t.string "parent_workflow_id", limit: 255, comment: "Workflow context for coordinated recovery"
    t.bigint "project_id", null: false
    t.datetime "updated_at", null: false
    t.index ["action_status"], name: "index_failure_classifications_on_action_status"
    t.index ["agent_run_id"], name: "index_failure_classifications_on_agent_run_id"
    t.index ["chosen_action"], name: "index_failure_classifications_on_chosen_action"
    t.index ["failure_category"], name: "index_failure_classifications_on_failure_category"
    t.index ["parent_workflow_id"], name: "index_failure_classifications_on_parent_workflow_id"
    t.index ["project_id", "created_at"], name: "idx_failure_classifications_project_created"
    t.index ["project_id"], name: "index_failure_classifications_on_project_id"
  end

  create_table "flipper_features", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "key", null: false
    t.datetime "updated_at", null: false
    t.index ["key"], name: "index_flipper_features_on_key", unique: true
  end

  create_table "flipper_gates", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "feature_key", null: false
    t.string "key", null: false
    t.datetime "updated_at", null: false
    t.text "value"
    t.index ["feature_key", "key", "value"], name: "index_flipper_gates_on_feature_key_and_key_and_value", unique: true
  end

  create_table "github_health_states", force: :cascade do |t|
    t.datetime "circuit_opened_at"
    t.string "circuit_state", limit: 20, default: "closed", null: false
    t.datetime "created_at", null: false
    t.string "endpoint", limit: 50, default: "api", null: false
    t.integer "failure_count", default: 0, null: false
    t.text "last_error_message"
    t.integer "rate_limit_limit", comment: "Total hourly request cap reported by GitHub for this credential (5,000 for PATs, 15,000 for App installations)."
    t.datetime "rate_limit_observed_at", comment: "When the remaining/limit rate-limit figures were last sampled from the GitHub API for this credential endpoint."
    t.integer "rate_limit_remaining"
    t.datetime "rate_limit_reset_at"
    t.datetime "rate_limited_until", comment: "Timestamp at which the GitHub API rate limit is expected to reset. While this is in the future the endpoint is treated as unavailable so the queue scheduler pauses dispatching."
    t.datetime "updated_at", null: false
    t.index ["endpoint"], name: "index_github_health_states_on_endpoint", unique: true
  end

  create_table "github_installations", comment: "Per-account GitHub App installation records for paid-agents[bot]", force: :cascade do |t|
    t.jsonb "accessible_repositories", default: [], null: false, comment: "Cached list of accessible repos from install metadata"
    t.bigint "account_id", null: false
    t.string "account_login", comment: "GitHub org or user login that installed the App"
    t.datetime "created_at", null: false
    t.bigint "github_installation_id", null: false, comment: "GitHub installation ID from App install event"
    t.datetime "repositories_synced_at", comment: "When accessible_repositories was last refreshed from the GitHub App installation API"
    t.string "repository_selection", comment: "all or selected"
    t.datetime "revoked_at", comment: "When the installation was uninstalled/deleted"
    t.datetime "suspended_at", comment: "When the installation was suspended by GitHub"
    t.string "target_type", comment: "Organization or User"
    t.datetime "updated_at", null: false
    t.index ["account_id", "github_installation_id"], name: "idx_github_installations_on_account_installation", unique: true
    t.index ["account_id"], name: "index_github_installations_on_account_id"
    t.index ["github_installation_id"], name: "index_github_installations_on_github_installation_id"
  end

  create_table "github_tokens", force: :cascade do |t|
    t.jsonb "accessible_repositories", default: [], null: false
    t.bigint "account_id", null: false
    t.datetime "created_at", null: false
    t.bigint "created_by_id"
    t.datetime "expires_at"
    t.datetime "last_used_at"
    t.jsonb "log_data"
    t.string "name", null: false
    t.integer "projects_count", default: 0, null: false
    t.datetime "repositories_synced_at"
    t.datetime "revoked_at"
    t.jsonb "scopes", default: [], null: false
    t.text "token", null: false
    t.datetime "updated_at", null: false
    t.text "validation_error"
    t.string "validation_status", limit: 50, default: "pending", null: false
    t.index ["account_id", "name"], name: "index_github_tokens_on_account_id_and_name", unique: true
    t.index ["account_id"], name: "index_github_tokens_on_account_id"
    t.index ["created_by_id"], name: "index_github_tokens_on_created_by_id"
    t.index ["revoked_at"], name: "index_github_tokens_on_revoked_at"
    t.index ["validation_status"], name: "index_github_tokens_on_validation_status"
  end

  create_table "good_job_batches", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.integer "callback_priority"
    t.text "callback_queue_name"
    t.datetime "created_at", null: false
    t.text "description"
    t.datetime "discarded_at"
    t.datetime "enqueued_at"
    t.datetime "finished_at"
    t.datetime "jobs_finished_at"
    t.text "on_discard"
    t.text "on_finish"
    t.text "on_success"
    t.jsonb "serialized_properties"
    t.datetime "updated_at", null: false
  end

  create_table "good_job_executions", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "active_job_id", null: false
    t.datetime "created_at", null: false
    t.interval "duration"
    t.text "error"
    t.text "error_backtrace", array: true
    t.integer "error_event", limit: 2
    t.datetime "finished_at"
    t.text "job_class"
    t.uuid "process_id"
    t.text "queue_name"
    t.datetime "scheduled_at"
    t.jsonb "serialized_params"
    t.datetime "updated_at", null: false
    t.index ["active_job_id", "created_at"], name: "index_good_job_executions_on_active_job_id_and_created_at"
    t.index ["process_id", "created_at"], name: "index_good_job_executions_on_process_id_and_created_at"
  end

  create_table "good_job_processes", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.integer "lock_type", limit: 2
    t.jsonb "state"
    t.datetime "updated_at", null: false
  end

  create_table "good_job_settings", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.text "key"
    t.datetime "updated_at", null: false
    t.jsonb "value"
    t.index ["key"], name: "index_good_job_settings_on_key", unique: true
  end

  create_table "good_jobs", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "active_job_id"
    t.uuid "batch_callback_id"
    t.uuid "batch_id"
    t.text "concurrency_key"
    t.datetime "created_at", null: false
    t.datetime "cron_at"
    t.text "cron_key"
    t.text "error"
    t.integer "error_event", limit: 2
    t.integer "executions_count"
    t.datetime "finished_at"
    t.boolean "is_discrete"
    t.text "job_class"
    t.text "labels", array: true
    t.datetime "locked_at"
    t.uuid "locked_by_id"
    t.datetime "performed_at"
    t.integer "priority"
    t.text "queue_name"
    t.uuid "retried_good_job_id"
    t.datetime "scheduled_at"
    t.jsonb "serialized_params"
    t.datetime "updated_at", null: false
    t.index ["active_job_id", "created_at"], name: "index_good_jobs_on_active_job_id_and_created_at"
    t.index ["batch_callback_id"], name: "index_good_jobs_on_batch_callback_id", where: "(batch_callback_id IS NOT NULL)"
    t.index ["batch_id"], name: "index_good_jobs_on_batch_id", where: "(batch_id IS NOT NULL)"
    t.index ["concurrency_key", "created_at"], name: "index_good_jobs_on_concurrency_key_and_created_at"
    t.index ["concurrency_key"], name: "index_good_jobs_on_concurrency_key_when_unfinished", where: "(finished_at IS NULL)"
    t.index ["cron_key", "created_at"], name: "index_good_jobs_on_cron_key_and_created_at_cond", where: "(cron_key IS NOT NULL)"
    t.index ["cron_key", "cron_at"], name: "index_good_jobs_on_cron_key_and_cron_at_cond", unique: true, where: "(cron_key IS NOT NULL)"
    t.index ["finished_at"], name: "index_good_jobs_jobs_on_finished_at_only", where: "(finished_at IS NOT NULL)"
    t.index ["job_class"], name: "index_good_jobs_on_job_class"
    t.index ["labels"], name: "index_good_jobs_on_labels", where: "(labels IS NOT NULL)", using: :gin
    t.index ["locked_by_id"], name: "index_good_jobs_on_locked_by_id", where: "(locked_by_id IS NOT NULL)"
    t.index ["priority", "created_at"], name: "index_good_job_jobs_for_candidate_lookup", where: "(finished_at IS NULL)"
    t.index ["priority", "created_at"], name: "index_good_jobs_jobs_on_priority_created_at_when_unfinished", order: { priority: "DESC NULLS LAST" }, where: "(finished_at IS NULL)"
    t.index ["priority", "scheduled_at"], name: "index_good_jobs_on_priority_scheduled_at_unfinished_unlocked", where: "((finished_at IS NULL) AND (locked_by_id IS NULL))"
    t.index ["queue_name", "scheduled_at"], name: "index_good_jobs_on_queue_name_and_scheduled_at", where: "(finished_at IS NULL)"
    t.index ["scheduled_at"], name: "index_good_jobs_on_scheduled_at", where: "(finished_at IS NULL)"
  end

  create_table "integration_credentials", force: :cascade do |t|
    t.bigint "account_id", null: false
    t.string "auth_kind", null: false
    t.string "category", null: false
    t.datetime "created_at", null: false
    t.bigint "created_by_id"
    t.datetime "expires_at"
    t.datetime "last_used_at"
    t.jsonb "log_data"
    t.jsonb "metadata", default: {}, null: false
    t.string "name", null: false
    t.datetime "revoked_at"
    t.text "secret", null: false
    t.string "service_key", null: false
    t.datetime "updated_at", null: false
    t.index ["account_id", "category"], name: "index_integration_credentials_on_account_id_and_category"
    t.index ["account_id", "revoked_at"], name: "index_integration_credentials_on_account_id_and_revoked_at"
    t.index ["account_id", "service_key", "name"], name: "idx_on_account_id_service_key_name_e4c03e1ea7", unique: true
    t.index ["account_id", "service_key"], name: "index_integration_credentials_on_account_id_and_service_key"
    t.index ["account_id"], name: "index_integration_credentials_on_account_id"
    t.index ["created_by_id"], name: "index_integration_credentials_on_created_by_id"
  end

  create_table "issue_dependencies", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "depends_on_issue_id"
    t.integer "depends_on_number"
    t.string "depends_on_owner"
    t.string "depends_on_repo"
    t.bigint "issue_id", null: false
    t.boolean "requires_deployment", default: false, null: false
    t.datetime "updated_at", null: false
    t.index ["depends_on_issue_id"], name: "index_issue_dependencies_on_depends_on_issue_id"
    t.index ["issue_id", "depends_on_issue_id"], name: "idx_issue_dependencies_unique", unique: true
    t.index ["issue_id", "depends_on_owner", "depends_on_repo", "depends_on_number"], name: "idx_issue_deps_external_unique", unique: true, where: "(depends_on_owner IS NOT NULL)"
    t.index ["issue_id"], name: "index_issue_dependencies_on_issue_id"
    t.check_constraint "depends_on_issue_id IS NOT NULL AND depends_on_owner IS NULL AND depends_on_repo IS NULL AND depends_on_number IS NULL OR depends_on_issue_id IS NULL AND NULLIF(depends_on_owner::text, ''::text) IS NOT NULL AND NULLIF(depends_on_repo::text, ''::text) IS NOT NULL AND depends_on_number > 0", name: "issue_dependencies_depends_on_xor"
  end

  create_table "issue_merge_subscriptions", comment: "One-shot per-user subscriptions for issue completion or pull request merge notifications.", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "issue_id", null: false, comment: "The synced issue row. Pull requests also use the issues table."
    t.string "subscription_type", default: "on_merge", null: false, comment: "Notification trigger type. on_merge covers PR merges and issue completion."
    t.datetime "updated_at", null: false
    t.bigint "user_id", null: false, comment: "The user who should receive the notification."
    t.index ["issue_id", "user_id", "subscription_type"], name: "index_issue_merge_subscriptions_on_dedup", unique: true
    t.index ["issue_id"], name: "index_issue_merge_subscriptions_on_issue_id"
    t.index ["user_id"], name: "index_issue_merge_subscriptions_on_user_id"
  end

  create_table "issues", force: :cascade do |t|
    t.boolean "auto_continue_paused", default: false, null: false
    t.text "body"
    t.datetime "ci_action_dispatched_at"
    t.datetime "ci_retry_requested_at"
    t.datetime "created_at", null: false
    t.datetime "deployed_at"
    t.integer "draft_review_count", default: 0, null: false
    t.integer "enhance_issue_rounds", default: 0, null: false
    t.datetime "github_created_at", null: false
    t.string "github_creator_login"
    t.bigint "github_issue_id", null: false
    t.integer "github_number", null: false
    t.string "github_state", null: false
    t.datetime "github_updated_at", null: false
    t.boolean "is_pull_request", default: false, null: false
    t.jsonb "labels", default: [], null: false
    t.datetime "last_pr_scan_at"
    t.datetime "merge_permission_rejected_at", comment: "When non-null, the most recent auto-merge attempt was rejected by GitHub because the App installation token lacks a required permission (e.g. `workflows` for a change under .github/workflows/). Such rejections are permanent until the App's permissions change, so this timestamp gates a retry cooldown instead of re-attempting every poll cycle."
    t.text "merge_permission_rejection_reason", comment: "Raw error message from the most recent merge-time GitHub App permission rejection, for operator visibility."
    t.datetime "operational_failure_reset_at"
    t.string "paid_state", default: "new", null: false
    t.bigint "parent_issue_id"
    t.boolean "paused", default: false, null: false, comment: "When true, mirrors the paid-paused GitHub label and excludes the issue from auto-pick. PR review/escalation automation is not yet gated by this flag."
    t.datetime "paused_at", comment: "Sync epoch: records when the pause state last transitioned (from UI or GitHub) to resolve bidirectional sync ordering."
    t.string "pr_escalation_reason", comment: "Machine-readable cause for the current PR escalation so only operational outages can auto-dismiss."
    t.integer "pr_followup_count", default: 0, null: false
    t.string "pr_review_phase", default: "draft", null: false
    t.bigint "project_id", null: false
    t.datetime "relationships_parsed_at"
    t.integer "review_goal_retry_count", default: 0, null: false
    t.datetime "review_goal_retry_reset_at"
    t.text "runner_retry_abandon_reason", comment: "Human-readable reason the issue was abandoned due to the retry cap."
    t.datetime "runner_retry_abandoned_at", comment: "When non-null, the issue was abandoned because every available provider reached the per-issue retry cap. Excluded from auto-pick until cleared (e.g. by a successful run)."
    t.string "source", default: "github", null: false
    t.integer "stuck_confirmation_count", default: 0, null: false, comment: "Number of consecutive scans that observed this PR in an escalation-eligible stuck state. Replaces the wall-clock no-progress window so Paid downtime (which produces no scans) cannot drive false escalations."
    t.string "title", limit: 1000, null: false
    t.datetime "updated_at", null: false
    t.index ["deployed_at"], name: "idx_issues_deployed_at_on_prs", where: "(is_pull_request = true)"
    t.index ["github_creator_login"], name: "index_issues_on_github_creator_login"
    t.index ["labels"], name: "index_issues_on_labels_gin_open_issues", where: "((is_pull_request = false) AND ((github_state)::text = 'open'::text))", using: :gin
    t.index ["labels"], name: "index_issues_on_labels_gin_open_prs", where: "((is_pull_request = true) AND ((github_state)::text = 'open'::text))", using: :gin
    t.index ["parent_issue_id"], name: "index_issues_on_parent_issue_id"
    t.index ["project_id", "github_issue_id"], name: "index_issues_on_project_id_and_github_issue_id", unique: true
    t.index ["project_id", "github_number"], name: "index_issues_on_project_id_and_github_number"
    t.index ["project_id", "is_pull_request", "pr_review_phase", "github_updated_at"], name: "idx_issues_project_pr_phase_updated_at_desc", order: { github_updated_at: :desc }
    t.index ["project_id", "paid_state"], name: "index_issues_on_project_id_and_paid_state"
    t.index ["project_id", "paused"], name: "index_issues_on_project_id_and_paused"
    t.index ["project_id", "pr_review_phase"], name: "idx_issues_pr_review_phase", where: "((is_pull_request = true) AND ((github_state)::text = 'open'::text))"
    t.index ["project_id", "source", "github_state"], name: "idx_issues_on_project_source_state"
    t.index ["project_id"], name: "index_issues_on_project_id"
    t.index ["relationships_parsed_at"], name: "index_issues_on_relationships_parsed_at"
    t.index ["source"], name: "index_issues_on_source"
  end

  create_table "knowledge_artifacts", force: :cascade do |t|
    t.string "artifact_type", limit: 100, null: false
    t.bigint "collector_run_id", null: false
    t.string "collector_type", limit: 100, null: false
    t.text "content"
    t.string "content_hash", limit: 64, null: false
    t.datetime "created_at", null: false
    t.string "identifier", limit: 500
    t.jsonb "metadata", default: {}
    t.bigint "project_id", null: false
    t.string "scope_path", limit: 1000
    t.string "status", limit: 50, default: "active", null: false
    t.datetime "updated_at", null: false
    t.index ["collector_run_id", "content_hash"], name: "index_knowledge_artifacts_on_collector_run_id_and_content_hash", unique: true
    t.index ["collector_run_id"], name: "index_knowledge_artifacts_on_collector_run_id"
    t.index ["identifier"], name: "index_knowledge_artifacts_on_identifier_trgm", opclass: :gin_trgm_ops, using: :gin
    t.index ["project_id", "artifact_type", "scope_path", "identifier", "collector_type", "status"], name: "idx_knowledge_artifacts_on_project_type_scope_id_ctype_status"
    t.index ["project_id", "artifact_type", "scope_path", "identifier", "collector_type"], name: "idx_knowledge_artifacts_active_unique", unique: true, where: "((status)::text = 'active'::text)"
    t.index ["project_id", "status", "artifact_type"], name: "idx_knowledge_artifacts_on_project_status_type", comment: "Covers GROUP BY artifact_type WHERE project_id AND status for project show page artifact counts"
    t.index ["project_id", "status", "identifier"], name: "idx_knowledge_artifacts_project_status_identifier"
    t.index ["project_id"], name: "index_knowledge_artifacts_on_project_id"
    t.index ["status"], name: "index_knowledge_artifacts_on_status"
  end

  create_table "knowledge_audit_events", force: :cascade do |t|
    t.string "actor_id", limit: 100
    t.string "actor_type", limit: 50
    t.datetime "created_at", null: false
    t.jsonb "details", default: {}
    t.string "event_type", limit: 100, null: false
    t.bigint "project_id", null: false
    t.string "target_id", limit: 100
    t.string "target_type", limit: 100
    t.index ["created_at"], name: "idx_knowledge_audit_events_on_created_at", using: :brin
    t.index ["event_type"], name: "index_knowledge_audit_events_on_event_type"
    t.index ["project_id", "created_at", "id"], name: "idx_knowledge_audit_events_on_project_created_at_id", order: { created_at: :desc, id: :desc }
    t.index ["project_id"], name: "index_knowledge_audit_events_on_project_id"
    t.index ["target_type", "target_id"], name: "index_knowledge_audit_events_on_target_type_and_target_id"
  end

  create_table "knowledge_chunks", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.string "chunk_type", limit: 50, null: false
    t.text "content", null: false
    t.string "content_hash", limit: 64, null: false
    t.tsvector "content_tsvector"
    t.datetime "created_at", null: false
    t.string "embedding_model", limit: 100
    t.bigint "knowledge_artifact_id", null: false
    t.bigint "project_id", null: false
    t.datetime "redaction_scanned_at"
    t.jsonb "scope_tags", default: []
    t.integer "sequence", default: 0
    t.string "status", limit: 50, default: "active", null: false
    t.datetime "updated_at", null: false
    t.index ["content_hash"], name: "index_knowledge_chunks_on_content_hash"
    t.index ["content_tsvector"], name: "index_knowledge_chunks_on_content_tsvector", using: :gin
    t.index ["knowledge_artifact_id"], name: "index_knowledge_chunks_on_knowledge_artifact_id"
    t.index ["project_id", "status", "knowledge_artifact_id", "sequence"], name: "idx_knowledge_chunks_project_status_artifact_sequence"
    t.index ["project_id", "status"], name: "index_knowledge_chunks_on_project_id_and_status"
    t.index ["project_id"], name: "index_knowledge_chunks_on_project_id"
  end

  create_table "knowledge_links", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "link_type", limit: 50, null: false
    t.jsonb "metadata", default: {}
    t.uuid "source_chunk_id", null: false
    t.uuid "target_chunk_id", null: false
    t.decimal "weight", precision: 5, scale: 3, default: "1.0"
    t.index ["link_type"], name: "index_knowledge_links_on_link_type"
    t.index ["source_chunk_id", "target_chunk_id", "link_type"], name: "idx_knowledge_links_uniqueness", unique: true
    t.index ["target_chunk_id"], name: "index_knowledge_links_on_target_chunk_id"
  end

  create_table "knowledge_recommendations", comment: "Actionable recommendations generated from knowledge-base usage patterns to improve repository context collection.", force: :cascade do |t|
    t.string "collector_type", limit: 100, comment: "Collector implicated by the recommendation when the action targets a specific collector."
    t.datetime "created_at", null: false
    t.text "description"
    t.text "dismissal_reason", comment: "Reason recorded when a recommendation is dismissed."
    t.datetime "dismissed_at", comment: "When the recommendation was dismissed."
    t.jsonb "evidence", default: {}, null: false, comment: "Structured supporting evidence explaining why the recommendation was generated."
    t.string "priority", limit: 20, default: "medium", null: false
    t.bigint "project_id", null: false
    t.string "recommendation_type", limit: 50, null: false, comment: "Recommendation category such as add_collector, remove_collector, improve_collector, or knowledge_gap."
    t.string "status", limit: 20, default: "pending", null: false, comment: "Recommendation workflow state: pending, accepted, dismissed, or implemented."
    t.datetime "updated_at", null: false
    t.index ["project_id", "recommendation_type"], name: "idx_on_project_id_recommendation_type_333faaed2e"
    t.index ["project_id", "status"], name: "index_knowledge_recommendations_on_project_id_and_status"
    t.index ["project_id"], name: "index_knowledge_recommendations_on_project_id"
  end

  create_table "knowledge_runs", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "final_provider", limit: 50
    t.integer "max_tokens"
    t.string "operation_type", limit: 50, null: false
    t.bigint "project_id", null: false
    t.jsonb "provider_attempts", default: [], null: false
    t.string "proxy_token", limit: 64
    t.string "status", limit: 50, default: "pending", null: false
    t.string "token_limit_status", limit: 50
    t.integer "total_tokens", default: 0, null: false
    t.datetime "updated_at", null: false
    t.index ["project_id", "status"], name: "index_knowledge_runs_on_project_id_and_status"
    t.index ["project_id"], name: "index_knowledge_runs_on_project_id"
    t.index ["proxy_token"], name: "index_knowledge_runs_on_proxy_token", unique: true
  end

  create_table "knowledge_usage_stats", comment: "Aggregates how an agent run consumed retrieved knowledge so search/bundle context effectiveness can be analyzed.", force: :cascade do |t|
    t.bigint "agent_run_id", null: false
    t.integer "artifact_count", default: 0, null: false, comment: "Number of distinct artifacts included in the retrieved context."
    t.string "artifact_type", limit: 100, null: false, comment: "Knowledge artifact category consumed by the run, such as code, docs, or decision records."
    t.integer "chunk_count", default: 0, null: false, comment: "Number of knowledge chunks included in the retrieved context."
    t.string "context_type", limit: 50, null: false, comment: "Retrieval mode used to supply context. Currently search or bundle."
    t.datetime "created_at", null: false
    t.string "goal", limit: 50, null: false, comment: "Agent run goal associated with the usage record, such as create_pr or review."
    t.jsonb "metadata", default: {}, null: false, comment: "Additional retrieval details used for reporting or debugging."
    t.bigint "project_id", null: false
    t.integer "token_count", default: 0, null: false, comment: "Approximate token cost of the retrieved knowledge context."
    t.datetime "updated_at", null: false
    t.index ["agent_run_id", "artifact_type", "context_type"], name: "idx_knowledge_usage_stats_unique", unique: true
    t.index ["agent_run_id"], name: "index_knowledge_usage_stats_on_agent_run_id"
    t.index ["artifact_type", "goal"], name: "index_knowledge_usage_stats_on_artifact_type_and_goal"
    t.index ["project_id", "created_at"], name: "index_knowledge_usage_stats_on_project_id_and_created_at"
    t.index ["project_id"], name: "index_knowledge_usage_stats_on_project_id"
  end

  create_table "linear_tokens", force: :cascade do |t|
    t.bigint "account_id", null: false
    t.datetime "created_at", null: false
    t.bigint "created_by_id"
    t.datetime "expires_at"
    t.datetime "last_used_at"
    t.string "name", null: false
    t.datetime "revoked_at"
    t.text "token", null: false
    t.datetime "updated_at", null: false
    t.string "validation_error"
    t.string "validation_status", default: "pending", null: false
    t.index ["account_id", "name"], name: "index_linear_tokens_on_account_id_and_name", unique: true
    t.index ["account_id"], name: "index_linear_tokens_on_account_id"
    t.index ["created_by_id"], name: "index_linear_tokens_on_created_by_id"
    t.index ["revoked_at"], name: "index_linear_tokens_on_revoked_at"
  end

  create_table "llm_models", force: :cascade do |t|
    t.boolean "active", default: true, null: false
    t.decimal "capability_score", precision: 4, scale: 2
    t.string "catalog_source", default: "seeded", null: false, comment: "How this model entered the catalog: seeded, openrouter_sync, or manual."
    t.string "category", limit: 50, default: "general", null: false
    t.integer "context_window"
    t.datetime "created_at", null: false
    t.string "data_training_risk", comment: "Whether provider terms indicate prompts may be used for training."
    t.string "display_name", null: false
    t.datetime "expires_at", comment: "Optional expiration time for temporary catalog entries."
    t.string "family", limit: 100
    t.bigint "free_variant_of_id", comment: "Paid model that this free model variant corresponds to."
    t.decimal "input_cost_per_million", precision: 10, scale: 4
    t.jsonb "log_data"
    t.integer "max_output_tokens"
    t.jsonb "metadata", default: {}, null: false
    t.string "model_id", null: false
    t.decimal "output_cost_per_million", precision: 10, scale: 4
    t.string "pricing_tier", default: "paid", null: false, comment: "Pricing availability for this model: paid, free, or freemium."
    t.string "provider", limit: 50, null: false
    t.boolean "supports_json_output", default: false, null: false
    t.boolean "supports_tools", default: false, null: false
    t.boolean "supports_vision", default: false, null: false
    t.string "tier", limit: 10
    t.datetime "updated_at", null: false
    t.index ["active"], name: "index_llm_models_on_active"
    t.index ["category"], name: "index_llm_models_on_category"
    t.index ["free_variant_of_id"], name: "index_llm_models_on_free_variant_of_id"
    t.index ["model_id"], name: "index_llm_models_on_model_id", unique: true
    t.index ["provider", "active"], name: "index_llm_models_on_provider_and_active"
    t.index ["provider"], name: "index_llm_models_on_provider"
    t.index ["tier"], name: "index_llm_models_on_tier"
    t.check_constraint "tier IS NULL OR (tier::text = ANY (ARRAY['low'::character varying::text, 'mid'::character varying::text, 'high'::character varying::text]))", name: "llm_models_tier_check"
  end

  create_table "llm_output_metrics", comment: "Stores scored quality signals for specific LLM-generated artifacts so prompt and output quality can be tracked over time.", force: :cascade do |t|
    t.bigint "account_id", null: false
    t.decimal "composite_score", precision: 5, scale: 4, comment: "Weighted aggregate quality score derived from the scores payload."
    t.datetime "created_at", null: false
    t.jsonb "metadata", default: {}, null: false, comment: "Additional scoring context used for reporting or troubleshooting."
    t.string "output_type", limit: 30, null: false, comment: "Artifact category being scored, such as pr_description, issue_title, or decision_record."
    t.bigint "project_id", null: false
    t.string "prompt_slug", limit: 100, null: false, comment: "Logical prompt identifier associated with the generated output."
    t.bigint "prompt_version_id"
    t.jsonb "scores", default: {}, null: false, comment: "Named metric scores used to evaluate the output before calculating any composite score."
    t.bigint "source_id", null: false, comment: "Primary key of the application record whose generated output was scored."
    t.string "source_type", limit: 30, null: false, comment: "Application record type referenced by source_id, such as PullRequest, Issue, or DecisionRecord."
    t.datetime "updated_at", null: false
    t.index ["account_id"], name: "index_llm_output_metrics_on_account_id"
    t.index ["output_type"], name: "index_llm_output_metrics_on_output_type"
    t.index ["project_id", "output_type", "created_at"], name: "idx_llm_output_metrics_project_type_time"
    t.index ["project_id", "output_type", "source_type", "source_id"], name: "idx_llm_output_metrics_unique_source", unique: true
    t.index ["project_id"], name: "index_llm_output_metrics_on_project_id"
    t.index ["prompt_slug", "prompt_version_id"], name: "idx_llm_output_metrics_slug_version"
    t.index ["prompt_version_id"], name: "index_llm_output_metrics_on_prompt_version_id"
    t.index ["source_type", "source_id"], name: "index_llm_output_metrics_on_source_type_and_source_id"
  end

  create_table "marketplace_entries", comment: "Team-shareable agent enhancements that can be attached to agent runs", force: :cascade do |t|
    t.bigint "account_id", null: false
    t.string "added_by_email", limit: 255, null: false
    t.string "added_by_name", limit: 255, null: false
    t.text "certification_notes", comment: "Operator-facing notes describing certification scope, evidence, or gaps."
    t.string "certification_status", limit: 50, default: "uncertified", null: false, comment: "Certification state used to communicate ecosystem support expectations."
    t.datetime "created_at", null: false
    t.bigint "current_version_id", comment: "Current active content snapshot for this marketplace entry."
    t.text "description"
    t.string "documentation_url", limit: 500, comment: "Primary documentation URL for installation and lifecycle guidance."
    t.string "entry_type", limit: 50, null: false, comment: "Logical enhancement category such as skill, plugin, or MCP server."
    t.jsonb "extension_points", default: [], null: false, comment: "Stable Paid extension points this entry targets, such as collectors or workflow strategies."
    t.string "name", limit: 255, null: false
    t.string "provider", limit: 100, comment: "Primary target runtime or provider family for this entry."
    t.string "provider_format", limit: 100, default: "canonical_v1", null: false, comment: "Default artifact schema or provider-native format identifier."
    t.string "source_code_url", limit: 500, comment: "Source repository or package URL for the extension payload."
    t.string "status", limit: 50, default: "draft", null: false, comment: "Lifecycle state for safe rollout and deprecation."
    t.string "support_tier", limit: 50, default: "community", null: false, comment: "Who supports the entry operationally: community, partner, or first-party."
    t.jsonb "tags", default: [], null: false, comment: "Searchable labels for browsing and matching."
    t.string "team_scope", limit: 50, default: "account", null: false, comment: "Marketplace visibility scope within the tenant."
    t.datetime "updated_at", null: false
    t.text "usage_guidance", comment: "Human guidance describing when the entry should be used."
    t.index ["account_id", "certification_status"], name: "idx_marketplace_entries_account_certification"
    t.index ["account_id", "entry_type", "status"], name: "idx_marketplace_entries_lookup"
    t.index ["account_id", "team_scope", "status"], name: "idx_marketplace_entries_scope"
    t.index ["account_id"], name: "index_marketplace_entries_on_account_id"
    t.index ["current_version_id"], name: "index_marketplace_entries_on_current_version_id"
    t.index ["extension_points"], name: "index_marketplace_entries_on_extension_points", using: :gin
    t.index ["tags"], name: "index_marketplace_entries_on_tags", using: :gin
  end

  create_table "marketplace_entry_rules", comment: "Account-scoped rules for auto-attaching or defaulting marketplace entries", force: :cascade do |t|
    t.jsonb "conditions", default: {}, null: false, comment: "Run-context conditions that must match before the entry attaches."
    t.datetime "created_at", null: false
    t.boolean "enabled", default: true, null: false
    t.bigint "marketplace_entry_id", null: false
    t.string "mode", limit: 50, null: false, comment: "Whether the rule is automatic matching or a team default."
    t.integer "position", default: 0, null: false
    t.text "rationale"
    t.datetime "updated_at", null: false
    t.index ["marketplace_entry_id", "mode", "position"], name: "index_marketplace_entry_rules_on_entry_mode_position"
    t.index ["marketplace_entry_id", "mode"], name: "index_marketplace_entry_rules_unique_mode", unique: true
    t.index ["marketplace_entry_id"], name: "index_marketplace_entry_rules_on_marketplace_entry_id"
  end

  create_table "marketplace_entry_versions", comment: "Immutable provider-content snapshots for marketplace entries", force: :cascade do |t|
    t.jsonb "canonical_artifact", default: {}, null: false, comment: "Canonical runtime artifact preserved for rendering into provider-specific payloads."
    t.text "changelog"
    t.jsonb "compatibility_constraints", default: {}, null: false, comment: "Provider, model, runtime, or tool constraints for attachment."
    t.datetime "created_at", null: false
    t.bigint "marketplace_entry_id", null: false
    t.jsonb "renderers", default: {}, null: false, comment: "Provider-specific renderers or native payload snapshots keyed by provider."
    t.jsonb "review_metadata", default: {}, null: false, comment: "Optional approval and review metadata for the version."
    t.datetime "updated_at", null: false
    t.integer "version", default: 1, null: false
    t.index ["marketplace_entry_id", "version"], name: "index_marketplace_entry_versions_unique_version", unique: true
    t.index ["marketplace_entry_id"], name: "index_marketplace_entry_versions_on_marketplace_entry_id"
  end

  create_table "mcp_server_definitions", force: :cascade do |t|
    t.bigint "account_id", null: false
    t.jsonb "args", default: [], null: false
    t.string "command", limit: 500
    t.datetime "created_at", null: false
    t.boolean "enabled", default: true, null: false
    t.jsonb "env", default: {}, null: false
    t.string "image", limit: 500
    t.string "install_type", limit: 50, null: false
    t.jsonb "log_data"
    t.jsonb "metadata", default: {}, null: false
    t.string "name", limit: 255, null: false
    t.string "transport", limit: 50, null: false
    t.datetime "updated_at", null: false
    t.string "url", limit: 2048
    t.index ["account_id", "enabled"], name: "index_mcp_server_definitions_on_account_id_and_enabled"
    t.index ["account_id", "name"], name: "index_mcp_server_definitions_on_account_id_and_name", unique: true
    t.index ["account_id"], name: "index_mcp_server_definitions_on_account_id"
  end

  create_table "model_selections", force: :cascade do |t|
    t.bigint "agent_run_id", null: false
    t.integer "budget_limit_cents"
    t.jsonb "candidates", default: [], null: false
    t.decimal "complexity_score", precision: 4, scale: 2
    t.datetime "created_at", null: false
    t.string "escalated_from_tier", limit: 10
    t.string "escalated_reason", limit: 255
    t.bigint "llm_model_id"
    t.text "reasoning"
    t.integer "selection_duration_ms"
    t.string "selector_type", limit: 50, null: false
    t.string "tier", limit: 10, null: false
    t.datetime "updated_at", null: false
    t.index ["agent_run_id"], name: "index_model_selections_on_agent_run_id", unique: true
    t.index ["llm_model_id"], name: "index_model_selections_on_llm_model_id"
    t.index ["selector_type"], name: "index_model_selections_on_selector_type"
    t.index ["tier"], name: "index_model_selections_on_tier"
    t.check_constraint "escalated_from_tier IS NULL OR (escalated_from_tier::text = ANY (ARRAY['low'::character varying::text, 'mid'::character varying::text, 'high'::character varying::text]))", name: "model_selections_escalated_from_tier_check"
    t.check_constraint "tier IS NULL OR (tier::text = ANY (ARRAY['low'::character varying::text, 'mid'::character varying::text, 'high'::character varying::text]))", name: "model_selections_tier_check"
  end

  create_table "notification_rule_states", force: :cascade do |t|
    t.bigint "account_id", null: false
    t.datetime "created_at", null: false
    t.datetime "first_seen_at"
    t.datetime "last_seen_at"
    t.jsonb "metadata", default: {}, null: false
    t.string "source", null: false
    t.bigint "subject_id", null: false
    t.string "subject_type", null: false
    t.datetime "updated_at", null: false
    t.index ["account_id", "source", "subject_type", "subject_id"], name: "index_notification_rule_states_on_dedup", unique: true
    t.index ["account_id"], name: "index_notification_rule_states_on_account_id"
    t.index ["subject_type", "subject_id"], name: "index_notification_rule_states_on_subject"
  end

  create_table "notifications", force: :cascade do |t|
    t.bigint "account_id", null: false
    t.string "action_url"
    t.datetime "created_at", null: false
    t.text "description"
    t.datetime "dismissed_at"
    t.jsonb "metadata", default: {}, null: false
    t.string "nav_section"
    t.datetime "read_at"
    t.datetime "resolved_at"
    t.integer "severity", default: 0, null: false
    t.string "source", null: false
    t.bigint "subject_id"
    t.string "subject_type"
    t.string "title", null: false
    t.datetime "updated_at", null: false
    t.bigint "user_id"
    t.index ["account_id", "nav_section", "read_at"], name: "index_notifications_on_badge"
    t.index ["account_id", "read_at", "dismissed_at"], name: "index_notifications_on_unread"
    t.index ["account_id", "source", "subject_type", "subject_id"], name: "index_notifications_on_dedup_account_wide", unique: true, where: "(user_id IS NULL)"
    t.index ["account_id", "user_id", "source", "subject_type", "subject_id"], name: "index_notifications_on_dedup", unique: true
    t.index ["subject_type", "subject_id"], name: "index_notifications_on_subject"
    t.index ["user_id"], name: "index_notifications_on_user_id"
  end

  create_table "onboarding_steps", force: :cascade do |t|
    t.bigint "account_id", null: false
    t.datetime "completed_at"
    t.datetime "created_at", null: false
    t.jsonb "metadata", default: {}
    t.integer "position", null: false
    t.string "status", default: "pending", null: false
    t.string "step", null: false
    t.datetime "updated_at", null: false
    t.index ["account_id", "position"], name: "index_onboarding_steps_on_account_id_and_position"
    t.index ["account_id", "step"], name: "index_onboarding_steps_on_account_id_and_step", unique: true
    t.index ["account_id"], name: "index_onboarding_steps_on_account_id"
  end

  create_table "orchestration_decisions", comment: "Structured log of orchestration decisions for later workflow analysis and learning.", force: :cascade do |t|
    t.string "actor", limit: 100, null: false, comment: "Component or role that made the decision, such as workflow, planner, scheduler, or human."
    t.bigint "agent_run_id", comment: "Agent run whose workflow emitted the decision when a specific run exists."
    t.jsonb "context", default: {}, null: false, comment: "Context snapshot used to make the decision, typically issue, project, and workflow features."
    t.datetime "created_at", null: false
    t.string "decision_type", limit: 100, null: false, comment: "Decision category such as decompose, select_agent, parallelize, retry, or escalate."
    t.jsonb "inputs", default: {}, null: false, comment: "Structured inputs or options considered before the decision."
    t.jsonb "outcome_references", default: [], null: false, comment: "References to later runs, metrics, or artifacts used to attribute outcomes back to this decision."
    t.jsonb "outputs", default: {}, null: false, comment: "Structured payload describing what the workflow decided."
    t.bigint "project_id", null: false, comment: "Owning project for tenant isolation and project-level analysis."
    t.bigint "strategy_version_id"
    t.datetime "updated_at", null: false
    t.index ["agent_run_id", "created_at", "id"], name: "idx_orchestration_decisions_run_recent"
    t.index ["agent_run_id", "decision_type", "created_at"], name: "idx_orchestration_decisions_run_type_created"
    t.index ["project_id", "actor", "created_at"], name: "idx_orchestration_decisions_project_actor_created"
    t.index ["project_id", "created_at", "id"], name: "idx_orchestration_decisions_project_recent"
    t.index ["project_id", "decision_type", "created_at"], name: "idx_orchestration_decisions_project_type_created"
    t.index ["strategy_version_id"], name: "index_orchestration_decisions_on_strategy_version_id"
  end

  create_table "orchestration_strategies", comment: "Persisted orchestration workflow configurations extracted from hardcoded defaults", force: :cascade do |t|
    t.bigint "account_id", comment: "NULL = system-wide default; set = account-level override"
    t.boolean "active", default: true, null: false, comment: "Whether this strategy is currently in effect"
    t.jsonb "configuration", default: {}, null: false, comment: "Strategy-specific configuration data"
    t.datetime "created_at", null: false
    t.string "idempotency_key"
    t.jsonb "log_data"
    t.string "name", null: false, comment: "Human-readable name for this strategy"
    t.string "strategy_type", null: false, comment: "Category: review_settings, quality_gate, execution_timeouts, retry_policies, agent_settings, feature_orchestration, provider_resolution"
    t.datetime "updated_at", null: false
    t.integer "version", default: 1, null: false, comment: "Monotonically increasing version for audit trail"
    t.index ["account_id", "strategy_type", "idempotency_key"], name: "index_orchestration_strategies_on_idempotency_key", unique: true, where: "(idempotency_key IS NOT NULL)"
    t.index ["account_id"], name: "index_orchestration_strategies_on_account_id"
    t.index ["active"], name: "index_orchestration_strategies_on_active"
    t.index ["strategy_type", "account_id"], name: "idx_orchestration_strategies_active_type_account", unique: true, where: "(active = true)", nulls_not_distinct: true
    t.index ["strategy_type"], name: "index_orchestration_strategies_on_strategy_type"
  end

  create_table "pending_install_claims", comment: "Server-side claims tying a freshly-returned GitHub App installation to a Paid account, so the signed `installation` webhook can finalize the GithubInstallation row for a first-time install into a brand-new org where the existing signals (project owner match, prior installation row) cannot resolve the account.", force: :cascade do |t|
    t.bigint "account_id", null: false
    t.datetime "created_at", null: false
    t.datetime "expires_at", null: false, comment: "When this claim becomes invalid; a stale claim must never authorize a binding"
    t.bigint "github_installation_id", null: false, comment: "GitHub installation ID returned by the post-install redirect (callback or setup_url)"
    t.string "source", null: false, comment: "How the claim was created: callback_with_state (user-initiated SaaS flow with verified CSRF state), operator_setup (self-hosted setup_url redirect, operator-authenticated)"
    t.string "state_token", comment: "Opaque CSRF state token tied to the user's session at install time; included for audit / forensic value, not used as a binding signal in itself"
    t.datetime "updated_at", null: false
    t.index ["account_id", "github_installation_id"], name: "idx_pending_install_claims_on_account_installation", unique: true
    t.index ["account_id"], name: "index_pending_install_claims_on_account_id"
    t.index ["expires_at"], name: "index_pending_install_claims_on_expires_at"
    t.index ["github_installation_id"], name: "index_pending_install_claims_on_github_installation_id"
  end

  create_table "pr_templates", force: :cascade do |t|
    t.bigint "account_id", null: false
    t.text "body", null: false
    t.datetime "created_at", null: false
    t.text "description"
    t.boolean "enabled", default: true, null: false
    t.jsonb "log_data"
    t.string "name", limit: 255, null: false
    t.integer "position", default: 0, null: false
    t.string "pr_type", limit: 50, default: "default", null: false
    t.bigint "project_id"
    t.datetime "updated_at", null: false
    t.bigint "user_id"
    t.index ["account_id", "name"], name: "idx_pr_templates_account_name_unique", unique: true, where: "((project_id IS NULL) AND (user_id IS NULL))"
    t.index ["account_id", "position"], name: "idx_pr_templates_account_position", where: "((project_id IS NULL) AND (user_id IS NULL))"
    t.index ["account_id"], name: "index_pr_templates_on_account_id"
    t.index ["project_id", "name"], name: "idx_pr_templates_project_name_unique", unique: true, where: "(project_id IS NOT NULL)"
    t.index ["project_id", "position"], name: "idx_pr_templates_project_position", where: "(project_id IS NOT NULL)"
    t.index ["project_id"], name: "index_pr_templates_on_project_id"
    t.index ["user_id", "name"], name: "idx_pr_templates_user_name_unique", unique: true, where: "((user_id IS NOT NULL) AND (project_id IS NULL))"
    t.index ["user_id", "position"], name: "idx_pr_templates_user_position", where: "(user_id IS NOT NULL)"
    t.index ["user_id"], name: "index_pr_templates_on_user_id"
    t.check_constraint "NOT (project_id IS NOT NULL AND user_id IS NOT NULL)", name: "pr_templates_scope_check"
  end

  create_table "pre_commit_requirements", force: :cascade do |t|
    t.bigint "account_id", null: false
    t.string "check_type", limit: 50, default: "shell_command", null: false
    t.text "command", null: false
    t.datetime "created_at", null: false
    t.boolean "enabled", default: true, null: false
    t.string "failure_behavior", limit: 50, default: "block", null: false
    t.text "fix_command"
    t.jsonb "log_data"
    t.string "name", limit: 255, null: false
    t.integer "position", default: 0, null: false
    t.bigint "project_id"
    t.datetime "updated_at", null: false
    t.bigint "user_id"
    t.index ["account_id", "name"], name: "idx_pre_commit_requirements_account_name_unique", unique: true, where: "((project_id IS NULL) AND (user_id IS NULL))"
    t.index ["account_id", "position"], name: "idx_pre_commit_requirements_account_position", where: "((project_id IS NULL) AND (user_id IS NULL))"
    t.index ["account_id"], name: "index_pre_commit_requirements_on_account_id"
    t.index ["project_id", "name"], name: "idx_pre_commit_requirements_project_name_unique", unique: true, where: "(project_id IS NOT NULL)"
    t.index ["project_id", "position"], name: "idx_pre_commit_requirements_project_position", where: "(project_id IS NOT NULL)"
    t.index ["project_id"], name: "index_pre_commit_requirements_on_project_id"
    t.index ["user_id", "name"], name: "idx_pre_commit_requirements_user_name_unique", unique: true, where: "((user_id IS NOT NULL) AND (project_id IS NULL))"
    t.index ["user_id", "position"], name: "idx_pre_commit_requirements_user_position", where: "(user_id IS NOT NULL)"
    t.index ["user_id"], name: "index_pre_commit_requirements_on_user_id"
    t.check_constraint "NOT (project_id IS NOT NULL AND user_id IS NOT NULL)", name: "chk_pre_commit_requirements_exclusive_scope"
  end

  create_table "preview_provision_states", comment: "Shared baseline snapshots for overlapping preview/screenshot provisioning on the same agent run.", force: :cascade do |t|
    t.integer "active_count", default: 0, null: false, comment: "Number of in-flight preview provisions currently sharing this baseline snapshot."
    t.bigint "agent_run_id", null: false
    t.jsonb "baseline_service_container_ids", default: [], null: false, comment: "Agent run service container ids before the first overlapping preview mutated the run state."
    t.jsonb "baseline_service_environment", default: {}, null: false, comment: "Agent run service environment before the first overlapping preview mutated the run state."
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["agent_run_id"], name: "index_preview_provision_states_on_agent_run_id", unique: true
  end

  create_table "preview_sessions", comment: "Live web app preview sessions bridging a tunnel port to the Rails reverse proxy for human review.", force: :cascade do |t|
    t.bigint "account_id", null: false, comment: "Owning account for tenant isolation and RLS."
    t.bigint "agent_run_id", comment: "Optional originating agent run that produced the previewed changes."
    t.string "branch_name", limit: 255, null: false, comment: "Git branch (or commit context) checked out in the preview container."
    t.string "container_id", limit: 128, comment: "Docker container id running the previewed web app behind the tunnel."
    t.datetime "created_at", null: false
    t.bigint "created_by_id", comment: "User who started the preview."
    t.text "error_message", comment: "Human-readable failure reason shown in the UI error state when status is failed."
    t.datetime "expires_at", null: false, comment: "Hard TTL after which the preview is stopped and its container/tunnel/port are reclaimed."
    t.string "framework", limit: 64, comment: "Detected web framework (rails, phoenix, django, nextjs, etc.) shown as preview metadata."
    t.datetime "last_accessed_at", comment: "Last time the proxy served a request for this session; used for idle-based expiry."
    t.datetime "last_active_at", comment: "Most recent time the preview was confirmed reachable/interacted with."
    t.bigint "project_id", null: false, comment: "Project the preview belongs to; drives account-scoped authorization."
    t.string "status", limit: 50, default: "pending", null: false, comment: "Lifecycle state: provisioning, starting, ready, active, expiring, stopped, failed."
    t.string "token", limit: 64, null: false, comment: "Opaque, random secret embedded in the proxy path /previews/:token/*. Acts as the proxy credential."
    t.integer "tunnel_port", comment: "Allocated localhost port on the Rails host that the rathole tunnel bridges to the container app."
    t.datetime "updated_at", null: false
    t.index ["account_id", "status", "expires_at"], name: "idx_preview_sessions_on_account_status_expires"
    t.index ["agent_run_id"], name: "index_preview_sessions_on_agent_run_id"
    t.index ["project_id", "created_at"], name: "index_preview_sessions_on_project_id_and_created_at", order: { created_at: :desc }
    t.index ["project_id", "status"], name: "index_preview_sessions_on_project_and_status"
    t.index ["project_id"], name: "index_preview_sessions_on_project_id"
    t.index ["status", "expires_at"], name: "index_preview_sessions_on_status_and_expires_at"
    t.index ["token"], name: "index_preview_sessions_on_token", unique: true
    t.index ["tunnel_port"], name: "index_preview_sessions_on_tunnel_port_active", unique: true, where: "((status)::text = ANY (ARRAY[('pending'::character varying)::text, ('provisioning'::character varying)::text, ('starting'::character varying)::text, ('ready'::character varying)::text]))"
  end

  create_table "preview_tunnel_port_reservations", comment: "Shared preview tunnel port reservations across Rails processes", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "reservation_key", null: false, comment: "Stable preview session key that owns the reserved port"
    t.integer "tunnel_port", null: false, comment: "Host-side TCP port reserved for the preview tunnel"
    t.datetime "updated_at", null: false
    t.index ["reservation_key"], name: "index_preview_tunnel_port_reservations_on_reservation_key", unique: true
    t.index ["tunnel_port"], name: "index_preview_tunnel_port_reservations_on_tunnel_port", unique: true
  end

  create_table "preview_tunnel_reservations", comment: "Tracks preview tunnel ports reserved across Ruby processes so concurrent preview boots cannot allocate the same port.", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "owner_key", comment: "Logical owner identifier for the process/session that reserved the preview tunnel port."
    t.integer "owner_pid", comment: "PID of the worker process that created the reservation so dead-worker leases can be reclaimed."
    t.integer "port", null: false, comment: "TCP port reserved for a preview tunnel listener on the control-plane host."
    t.datetime "updated_at", null: false
    t.index ["port"], name: "index_preview_tunnel_reservations_on_port", unique: true
  end

  create_table "project_baselines", comment: "Stores per-project historical baselines for run metrics so anomalies can be detected against recent norms.", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.datetime "last_calculated_at", comment: "When the baseline values were last recomputed."
    t.float "mean", default: 0.0, null: false, comment: "Historical mean value for the tracked metric."
    t.string "metric_name", limit: 50, null: false, comment: "Tracked agent run metric summarized by this baseline, such as tokens_total, duration_seconds, iterations, or cost_cents."
    t.float "p95", default: 0.0, null: false, comment: "Ninety-fifth percentile for the tracked metric."
    t.bigint "project_id", null: false
    t.integer "sample_count", default: 0, null: false, comment: "Number of runs contributing to the baseline calculation."
    t.float "standard_deviation", default: 0.0, null: false, comment: "Historical standard deviation for the tracked metric."
    t.datetime "updated_at", null: false
    t.index ["project_id", "metric_name"], name: "index_project_baselines_on_project_id_and_metric_name", unique: true
    t.index ["project_id"], name: "index_project_baselines_on_project_id"
  end

  create_table "project_convention_detections", comment: "Repository-derived convention detections captured for a specific project version.", force: :cascade do |t|
    t.string "category", comment: "Typed convention category, such as commit_convention_policy or hook_system."
    t.decimal "confidence", precision: 4, scale: 3, default: "1.0", null: false, comment: "Detector confidence from 0.0 to 1.0."
    t.datetime "created_at", null: false
    t.datetime "detected_at", null: false, comment: "Timestamp when the repository scan produced this detection."
    t.string "detector_key", null: false, comment: "Detector responsible for producing this normalized convention record."
    t.jsonb "evidence", default: {}, null: false, comment: "Structured supporting evidence with source files and matched signals."
    t.string "key", null: false, comment: "Convention key detected from repository evidence."
    t.bigint "project_id", null: false, comment: "Project whose repository conventions were detected."
    t.bigint "project_version_id", null: false, comment: "Project version whose tree was scanned."
    t.datetime "updated_at", null: false
    t.jsonb "value", default: {}, null: false, comment: "Normalized detected convention payload."
    t.index ["project_id", "key"], name: "index_project_convention_detections_on_project_id_and_key"
    t.index ["project_id"], name: "index_project_convention_detections_on_project_id"
    t.index ["project_version_id", "key", "detector_key"], name: "idx_project_convention_detections_unique_detector", unique: true
    t.index ["project_version_id"], name: "index_project_convention_detections_on_project_version_id"
  end

  create_table "project_convention_overrides", comment: "Explicit per-project overrides for detected repository conventions.", force: :cascade do |t|
    t.string "category", comment: "Typed convention category, such as commit_convention_policy or hook_system."
    t.datetime "created_at", null: false
    t.boolean "enabled", default: true, null: false, comment: "Disabled overrides act as tombstones against detected defaults."
    t.string "key", null: false, comment: "Convention key being overridden, such as commit_messages."
    t.string "mode", default: "apply", null: false, comment: "Override handling policy: apply, warn, or ignore."
    t.bigint "project_id", null: false, comment: "Project receiving the explicit convention override."
    t.text "rationale", comment: "User-entered reason for overriding the detected convention."
    t.datetime "updated_at", null: false
    t.jsonb "value", default: {}, null: false, comment: "Explicit project-scoped convention override payload."
    t.index ["project_id", "key"], name: "index_project_convention_overrides_on_project_id_and_key", unique: true
    t.index ["project_id"], name: "index_project_convention_overrides_on_project_id"
  end

  create_table "project_convention_recommendations", comment: "Actionable convention-based recommendations for a project, with dismissal and audit tracking.", force: :cascade do |t|
    t.string "action_type", limit: 50, null: false, comment: "Recommended action: apply_in_paid, open_pr, apply_github_side"
    t.datetime "applied_at", comment: "When the recommendation was applied"
    t.bigint "applied_by_id", comment: "User who applied the recommendation"
    t.string "convention_key", limit: 100, null: false, comment: "Convention key this recommendation relates to (e.g. commit_style, hook_manager)"
    t.datetime "created_at", null: false
    t.text "description", null: false, comment: "Explanation of why the recommendation exists and what it does"
    t.string "dismissal_reason", comment: "User-provided reason for dismissal"
    t.datetime "dismissed_at", comment: "When the recommendation was dismissed"
    t.bigint "dismissed_by_id", comment: "User who dismissed the recommendation"
    t.jsonb "evidence", default: {}, null: false, comment: "Supporting evidence from detection that triggered this recommendation"
    t.datetime "generated_at", comment: "When the recommendation was generated from detection data"
    t.bigint "project_id", null: false, comment: "The project this recommendation belongs to"
    t.string "status", limit: 30, default: "pending", null: false, comment: "Lifecycle: pending, applied, dismissed"
    t.string "title", limit: 255, null: false, comment: "Short human-readable recommendation title"
    t.datetime "updated_at", null: false
    t.index ["applied_by_id"], name: "index_project_convention_recommendations_on_applied_by_id"
    t.index ["dismissed_by_id"], name: "index_project_convention_recommendations_on_dismissed_by_id"
    t.index ["project_id", "convention_key", "action_type"], name: "index_convention_recs_on_project_key_action", unique: true, where: "((status)::text = 'pending'::text)"
    t.index ["project_id", "status"], name: "index_convention_recs_on_project_status"
    t.index ["project_id"], name: "index_project_convention_recommendations_on_project_id"
  end

  create_table "project_mcp_servers", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "mcp_server_definition_id", null: false
    t.bigint "project_id", null: false
    t.datetime "updated_at", null: false
    t.index ["mcp_server_definition_id"], name: "index_project_mcp_servers_on_mcp_server_definition_id"
    t.index ["project_id", "mcp_server_definition_id"], name: "idx_project_mcp_servers_unique", unique: true
    t.index ["project_id"], name: "index_project_mcp_servers_on_project_id"
  end

  create_table "project_memberships", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.jsonb "log_data"
    t.bigint "project_id", null: false
    t.integer "role", default: 0, null: false
    t.datetime "updated_at", null: false
    t.bigint "user_id", null: false
    t.index ["project_id", "role"], name: "index_project_memberships_on_project_id_and_role"
    t.index ["project_id"], name: "index_project_memberships_on_project_id"
    t.index ["user_id", "project_id"], name: "index_project_memberships_on_user_id_and_project_id", unique: true
    t.index ["user_id"], name: "index_project_memberships_on_user_id"
  end

  create_table "project_service_containers", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "project_id", null: false
    t.bigint "service_container_id", null: false
    t.datetime "updated_at", null: false
    t.index ["project_id", "service_container_id"], name: "idx_project_service_containers_unique", unique: true
    t.index ["project_id"], name: "index_project_service_containers_on_project_id"
    t.index ["service_container_id"], name: "index_project_service_containers_on_service_container_id"
  end

  create_table "project_versions", force: :cascade do |t|
    t.string "branch", default: "main", null: false
    t.string "commit_sha", limit: 40, null: false
    t.datetime "committed_at"
    t.datetime "created_at", null: false
    t.jsonb "metadata", default: {}
    t.string "parent_sha", limit: 40
    t.bigint "project_id", null: false
    t.datetime "updated_at", null: false
    t.index ["project_id", "commit_sha"], name: "index_project_versions_on_project_id_and_commit_sha", unique: true
    t.index ["project_id", "committed_at"], name: "index_project_versions_on_project_id_and_committed_at", order: { committed_at: :desc }
    t.index ["project_id"], name: "index_project_versions_on_project_id"
  end

  create_table "projects", force: :cascade do |t|
    t.bigint "account_id", null: false
    t.boolean "active", default: true, null: false
    t.integer "agent_runs_count", default: 0, null: false, comment: "Counter cache for total agent runs"
    t.boolean "allow_bot_authored_pr_auto_merge", default: false, null: false, comment: "When true, PRs authored by the project's own GitHub App bot may auto-merge without explicit owner approval"
    t.jsonb "allowed_github_usernames", default: [], null: false
    t.boolean "auto_add_labels_enabled", default: true, null: false
    t.boolean "auto_enhance_enabled", default: false, null: false
    t.boolean "auto_fix_merge_conflicts", default: true, null: false
    t.string "auto_merge_mode", default: "off", null: false
    t.boolean "auto_pick_enabled", default: false, null: false
    t.jsonb "auto_pick_skip_labels", comment: "Optional project-level override for labels that make auto-pick skip an issue. Null means inherit user, tenant, or built-in defaults."
    t.string "auto_release_granularity", default: "off", null: false
    t.boolean "auto_scan_prs", default: true, null: false
    t.boolean "auto_scan_security", default: false, null: false
    t.string "automation_label_name", default: "paid-automation", null: false
    t.boolean "automation_on_label_enabled", default: true, null: false
    t.integer "code_scanning_interval_hours", default: 24, null: false
    t.datetime "code_scanning_permission_error_at", comment: "Timestamp of the most recent 403 (missing security_events/code_scanning_alerts:read permission) hit while scanning for code scanning alerts. Used to back off retrying a scan that will fail identically until a human fixes the token/App permission, without waiting the full code_scanning_interval_hours window. Cleared on the next successful scan."
    t.integer "completed_agent_runs_count", default: 0, null: false, comment: "Counter cache for completed agent runs"
    t.datetime "created_at", null: false
    t.bigint "created_by_id"
    t.string "data_classification", default: "internal", null: false, comment: "Sensitivity level for project data shared with model providers."
    t.string "default_branch", default: "main", null: false
    t.string "enhance_issue_enhanced_label_name", default: "paid-enhanced", null: false
    t.string "enhance_issue_needs_input_label_name", default: "paid-needs-input", null: false
    t.jsonb "fitness_settings", default: {}, null: false
    t.string "generated_label_name", default: "paid-generated", null: false
    t.bigint "git_push_fallback_token_id", comment: "Optional PAT (selected in project settings) used as the git push credential when git_push_pat_fallback_enabled is set and the GitHub App installation token is rejected for a missing permission (e.g. a push under .github/workflows/). The App stays the default for all other operations."
    t.boolean "git_push_pat_fallback_enabled", default: false, null: false, comment: "When true, an app-backed project retries a git push with its git_push_fallback_token PAT if the GitHub App installation token is rejected for a missing permission (e.g. a push touching .github/workflows/). Opt-in; the App remains the default credential for every other operation."
    t.bigint "github_id", null: false
    t.bigint "github_installation_id", comment: "GitHub App installation for repo auth; mutually exclusive with github_token_id"
    t.bigint "github_token_id"
    t.boolean "inherit_priority_labels", default: true, null: false
    t.jsonb "interop_settings", default: {}, null: false, comment: "Project-level coexistence settings for gradual adoption, imports, connectors, and external execution sources."
    t.boolean "knowledge_evolution_enabled", default: false, null: false
    t.string "knowledge_status", limit: 50, default: "pending", null: false
    t.jsonb "label_mappings", default: {}, null: false
    t.datetime "last_agent_run_at"
    t.datetime "last_code_scanning_scan_at"
    t.datetime "last_github_activity_at"
    t.datetime "last_issue_reconciliation_at", comment: "Timestamp of the last issue state reconciliation against GitHub"
    t.datetime "last_issue_sync_at"
    t.datetime "last_polled_at"
    t.jsonb "lid_detection", default: {}, null: false, comment: "Repository-derived LID detection metadata such as version, sources, warnings, and detection time."
    t.string "lid_mode", comment: "Effective Linked-Intent Development mode detected from the repository or forced in settings."
    t.boolean "lid_mode_overridden", default: false, null: false, comment: "True when the project owner has manually forced lid_mode from settings. Repo-driven detection during import/sync leaves lid_mode untouched while this is true, until an explicit re-detect is requested."
    t.jsonb "log_data"
    t.integer "max_draft_review_rounds", default: 10, null: false
    t.integer "max_enhance_issue_reevaluation_rounds", default: 3, null: false
    t.integer "max_execution_seconds", default: 7200, null: false
    t.integer "max_issue_runner_failures", comment: "Per-project override for the per-issue per-provider retry cap. When nil, the account-level agent setting (default 10) applies. After a provider fails this many times for a single issue it is excluded from scheduling for that issue."
    t.integer "max_pr_followup_runs", default: 8, null: false
    t.integer "max_tokens_per_run"
    t.string "merge_method", default: "squash", null: false
    t.jsonb "model_preferences", default: {}, null: false
    t.string "name", null: false
    t.string "owner", null: false
    t.string "owner_reviewer_login"
    t.boolean "paused", default: false, null: false, comment: "When true, queued automatic agent runs for this project will not be started. Manual runs are unaffected."
    t.integer "plan_review_timeout_hours", default: 24, null: false, comment: "Maximum hours to wait for plan review approval before auto-approving."
    t.integer "poll_interval_seconds", default: 60, null: false
    t.jsonb "pr_action_labels", default: [], null: false
    t.boolean "pr_aggregation_enabled", default: false, null: false
    t.string "preferred_docker_host_identifier", comment: "Optional project-level Docker host preference overriding the account default for manual placement."
    t.string "primary_language", comment: "Primary language of the repository as reported by GitHub (e.g. Ruby, Elixir, Swift). Used to detect and badge the project type."
    t.jsonb "priority_labels", default: {"P1" => "P1", "P2" => "P2", "P3" => "P3"}, null: false
    t.jsonb "quality_gate_settings", default: {}, null: false
    t.jsonb "quality_pause_metadata", default: {}, null: false
    t.datetime "quality_paused_at"
    t.string "repo", null: false
    t.jsonb "review_settings", default: {}, null: false
    t.string "scheduler_pause_reason"
    t.datetime "scheduler_paused_at"
    t.jsonb "screenshot_settings", default: {}, null: false, comment: "Project-level defaults and overrides for repository screenshot capture config"
    t.jsonb "screenshot_status", default: {}, null: false, comment: "Latest screenshot capture status shown in project settings."
    t.jsonb "security_alert_types", default: ["code_scanning"], null: false
    t.integer "token_budget_max_input_tokens", comment: "Per-run input token budget; runs exceeding it without output are terminated early (nil = defer to provider/global default)"
    t.integer "token_limit_warning_threshold", default: 80, null: false
    t.bigint "total_cost_cents", default: 0, null: false
    t.bigint "total_tokens_used", default: 0, null: false
    t.datetime "updated_at", null: false
    t.text "webhook_secret"
    t.index "account_id, lower((owner)::text), lower((name)::text)", name: "index_projects_on_account_id_and_lower_owner_name"
    t.index ["account_id", "active"], name: "index_projects_on_account_id_and_active"
    t.index ["account_id", "github_id"], name: "index_projects_on_account_id_and_github_id", unique: true
    t.index ["account_id", "last_agent_run_at"], name: "index_projects_on_account_id_and_last_agent_run_at"
    t.index ["account_id", "last_github_activity_at"], name: "index_projects_on_account_id_and_last_github_activity_at"
    t.index ["account_id"], name: "index_projects_on_account_id"
    t.index ["created_by_id"], name: "index_projects_on_created_by_id"
    t.index ["git_push_fallback_token_id"], name: "index_projects_on_git_push_fallback_token_id"
    t.index ["github_installation_id"], name: "index_projects_on_github_installation_id"
    t.index ["github_token_id"], name: "index_projects_on_github_token_id"
    t.index ["lid_mode"], name: "index_projects_on_lid_mode"
    t.index ["owner", "repo"], name: "index_projects_on_owner_and_repo"
    t.index ["quality_paused_at"], name: "index_projects_on_quality_paused_at", where: "(quality_paused_at IS NOT NULL)"
    t.index ["scheduler_paused_at"], name: "index_projects_on_scheduler_paused_at", where: "(scheduler_paused_at IS NOT NULL)"
    t.check_constraint "github_token_id IS NOT NULL AND github_installation_id IS NULL OR github_token_id IS NULL AND github_installation_id IS NOT NULL", name: "chk_projects_exactly_one_github_credential"
  end

  create_table "prompt_versions", force: :cascade do |t|
    t.decimal "avg_iterations", precision: 4, scale: 2
    t.decimal "avg_quality_score", precision: 4, scale: 2
    t.text "change_notes"
    t.datetime "created_at", null: false
    t.string "created_by", limit: 50
    t.bigint "created_by_user_id"
    t.string "idempotency_key"
    t.bigint "parent_version_id"
    t.bigint "prompt_id", null: false
    t.datetime "retired_at"
    t.text "review_notes"
    t.string "review_status", limit: 20
    t.datetime "reviewed_at"
    t.bigint "reviewed_by_user_id"
    t.text "system_prompt"
    t.text "template", null: false
    t.integer "usage_count", default: 0, null: false
    t.jsonb "variables", default: [], null: false
    t.integer "version", null: false
    t.index ["created_by_user_id"], name: "index_prompt_versions_on_created_by_user_id"
    t.index ["parent_version_id"], name: "index_prompt_versions_on_parent_version_id"
    t.index ["prompt_id", "idempotency_key"], name: "index_prompt_versions_on_prompt_and_idempotency_key", unique: true, where: "(idempotency_key IS NOT NULL)"
    t.index ["prompt_id", "review_status"], name: "index_prompt_versions_on_prompt_and_review_status", where: "(review_status IS NOT NULL)"
    t.index ["prompt_id", "version"], name: "index_prompt_versions_on_prompt_id_and_version", unique: true
    t.index ["prompt_id"], name: "index_prompt_versions_on_prompt_id"
    t.index ["retired_at"], name: "index_prompt_versions_on_retired_at"
    t.index ["reviewed_by_user_id"], name: "index_prompt_versions_on_reviewed_by_user_id"
  end

  create_table "prompts", force: :cascade do |t|
    t.bigint "account_id"
    t.boolean "active", default: true, null: false
    t.string "category", limit: 50, null: false
    t.datetime "created_at", null: false
    t.bigint "current_version_id"
    t.text "description"
    t.jsonb "log_data"
    t.string "name", limit: 255, null: false
    t.bigint "project_id"
    t.boolean "requires_review", default: false, null: false
    t.string "slug", limit: 100, null: false
    t.datetime "updated_at", null: false
    t.index ["account_id"], name: "index_prompts_on_account_id"
    t.index ["active"], name: "index_prompts_on_active"
    t.index ["category"], name: "index_prompts_on_category"
    t.index ["current_version_id"], name: "index_prompts_on_current_version_id"
    t.index ["project_id"], name: "index_prompts_on_project_id"
    t.index ["slug", "account_id"], name: "index_prompts_on_slug_account", unique: true, where: "((account_id IS NOT NULL) AND (project_id IS NULL))"
    t.index ["slug", "project_id"], name: "index_prompts_on_slug_project", unique: true, where: "(project_id IS NOT NULL)"
    t.index ["slug"], name: "index_prompts_on_slug_global", unique: true, where: "((account_id IS NULL) AND (project_id IS NULL))"
    t.check_constraint "project_id IS NULL OR account_id IS NOT NULL", name: "chk_prompts_scope_consistency"
  end

  create_table "provider_api_keys", force: :cascade do |t|
    t.text "api_key", null: false
    t.string "api_service_type", limit: 50, null: false
    t.datetime "created_at", null: false
    t.jsonb "log_data"
    t.string "name", limit: 100, null: false
    t.datetime "updated_at", null: false
    t.bigint "user_id", null: false
    t.index ["user_id", "api_service_type"], name: "index_provider_api_keys_on_user_id_and_api_service_type"
    t.index ["user_id", "name"], name: "index_provider_api_keys_on_user_id_and_name", unique: true
    t.index ["user_id"], name: "index_provider_api_keys_on_user_id"
  end

  create_table "quality_gate_events", comment: "Records each threshold breach and recovery observed by the quality gate system.", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "event_type", limit: 20, null: false, comment: "Quality gate transition being recorded: trigger or recovery."
    t.jsonb "metadata", default: {}, null: false, comment: "Structured context about the gate evaluation and follow-up actions."
    t.bigint "project_id", null: false
    t.bigint "quality_gate_threshold_id", null: false
    t.bigint "quality_metric_id", null: false
    t.decimal "score_value", precision: 5, scale: 4, null: false, comment: "Observed metric value that triggered the event."
    t.decimal "threshold_value", precision: 5, scale: 4, null: false, comment: "Specific threshold value that was breached or recovered."
    t.datetime "updated_at", null: false
    t.index ["project_id", "event_type", "created_at"], name: "idx_quality_gate_events_project_type_time"
    t.index ["project_id"], name: "index_quality_gate_events_on_project_id"
    t.index ["quality_gate_threshold_id"], name: "index_quality_gate_events_on_quality_gate_threshold_id"
    t.index ["quality_metric_id"], name: "index_quality_gate_events_on_quality_metric_id"
  end

  create_table "quality_gate_thresholds", comment: "Defines per-project quality gate rules that trigger pauses or recovery when metrics breach expected bounds.", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.boolean "enabled", default: true, null: false, comment: "Whether this threshold currently participates in quality gate evaluation."
    t.jsonb "log_data"
    t.decimal "max_threshold", precision: 5, scale: 4, comment: "Upper bound whose breach triggers the gate for metrics where too high is bad."
    t.string "metric_key", limit: 50, null: false, comment: "Quality metric evaluated by the gate, such as composite_score, lint_clean, or review_score."
    t.decimal "min_threshold", precision: 5, scale: 4, comment: "Lower bound whose breach triggers the gate for metrics where too low is bad."
    t.bigint "project_id", null: false
    t.string "severity", limit: 20, default: "warning", null: false, comment: "Severity assigned when the gate is breached: info, warning, or critical."
    t.datetime "updated_at", null: false
    t.index ["project_id", "enabled", "metric_key"], name: "idx_quality_gate_thresholds_project_enabled_metric"
    t.index ["project_id", "metric_key"], name: "index_quality_gate_thresholds_on_project_id_and_metric_key", unique: true
    t.index ["project_id"], name: "index_quality_gate_thresholds_on_project_id"
  end

  create_table "quality_metrics", force: :cascade do |t|
    t.bigint "agent_run_id", null: false
    t.decimal "composite_score", precision: 5, scale: 4
    t.datetime "created_at", null: false
    t.string "feedback_source", limit: 50
    t.jsonb "metadata", default: {}, null: false
    t.string "metric_type", limit: 20, null: false
    t.decimal "mutation_kill_rate", precision: 5, scale: 4, comment: "Mutant kill rate for the agent run when mutation testing executed; nil means mutant did not run or produced no score."
    t.bigint "prompt_version_id"
    t.jsonb "scores", default: {}, null: false
    t.string "source", default: "agent_run", null: false, comment: "Origin of the metric row so scheduled mutation sweeps stay distinct from per-agent-run quality metrics."
    t.datetime "updated_at", null: false
    t.index ["agent_run_id", "metric_type"], name: "index_quality_metrics_on_agent_run_and_type", unique: true
    t.index ["agent_run_id"], name: "index_quality_metrics_on_agent_run_id"
    t.index ["composite_score"], name: "index_quality_metrics_on_composite_score"
    t.index ["created_at"], name: "index_quality_metrics_on_created_at"
    t.index ["metric_type"], name: "index_quality_metrics_on_metric_type"
    t.index ["prompt_version_id", "created_at"], name: "idx_quality_metrics_prompt_recent_composite", order: { created_at: :desc }, where: "(composite_score IS NOT NULL)"
    t.index ["prompt_version_id", "created_at"], name: "index_quality_metrics_on_prompt_version_and_created_at"
    t.index ["prompt_version_id"], name: "index_quality_metrics_on_prompt_version_id"
    t.index ["source"], name: "index_quality_metrics_on_source"
  end

  create_table "quality_pause_events", comment: "Audit trail for project-level automatic pauses and resumptions caused by quality gate outcomes.", force: :cascade do |t|
    t.bigint "agent_run_id"
    t.decimal "composite_score", precision: 5, scale: 4, comment: "Composite quality score observed when the pause or resume decision was made."
    t.datetime "created_at", null: false
    t.string "event_type", limit: 20, null: false, comment: "Pause lifecycle event: paused when automation is halted or resumed when it is re-enabled."
    t.jsonb "metadata", default: {}, null: false, comment: "Structured context for the pause decision, including contributing signals."
    t.bigint "project_id", null: false
    t.decimal "threshold", precision: 5, scale: 4, comment: "Composite score threshold that justified the pause or resume event."
    t.datetime "updated_at", null: false
    t.index ["agent_run_id"], name: "index_quality_pause_events_on_agent_run_id"
    t.index ["project_id", "created_at"], name: "index_quality_pause_events_on_project_id_and_created_at"
    t.index ["project_id"], name: "index_quality_pause_events_on_project_id"
  end

  create_table "quality_recovery_actions", comment: "Tracks remediation steps proposed or executed after a quality gate pause so recovery effectiveness can be measured.", force: :cascade do |t|
    t.string "action_type", limit: 50, null: false, comment: "Recovery strategy being attempted, such as prompt_rollback, model_change, or final_pause."
    t.bigint "agent_run_id"
    t.datetime "created_at", null: false
    t.jsonb "diagnosis", default: {}, null: false, comment: "Structured diagnosis explaining why this recovery action was selected."
    t.datetime "evaluated_at", comment: "When the impact of the recovery action was evaluated."
    t.datetime "executed_at", comment: "When execution of the recovery action began or completed."
    t.jsonb "parameters", default: {}, null: false, comment: "Inputs required to execute the recovery action."
    t.bigint "project_id", null: false
    t.bigint "prompt_version_id"
    t.decimal "quality_after", precision: 5, scale: 4, comment: "Quality score measured after the recovery action was evaluated."
    t.decimal "quality_before", precision: 5, scale: 4, comment: "Quality score before the recovery action was executed."
    t.jsonb "result", default: {}, null: false, comment: "Structured output and evaluation details produced by the recovery action."
    t.string "status", limit: 50, default: "pending", null: false, comment: "Execution state for the recovery action: pending, executing, executed, evaluated, or failed."
    t.datetime "updated_at", null: false
    t.index ["action_type"], name: "index_quality_recovery_actions_on_action_type"
    t.index ["agent_run_id"], name: "index_quality_recovery_actions_on_agent_run_id"
    t.index ["project_id", "created_at"], name: "index_quality_recovery_actions_on_project_id_and_created_at"
    t.index ["project_id"], name: "index_quality_recovery_actions_on_project_id"
    t.index ["prompt_version_id"], name: "index_quality_recovery_actions_on_prompt_version_id"
    t.index ["status"], name: "index_quality_recovery_actions_on_status"
  end

  create_table "quality_thresholds", force: :cascade do |t|
    t.bigint "account_id", null: false
    t.datetime "created_at", null: false
    t.boolean "enabled", default: true, null: false
    t.string "goal_type", limit: 50, null: false
    t.jsonb "log_data"
    t.string "metric_type", limit: 50, null: false
    t.decimal "min_value", precision: 5, scale: 4, null: false
    t.bigint "project_id"
    t.datetime "updated_at", null: false
    t.index ["account_id", "metric_type", "goal_type"], name: "index_quality_thresholds_on_account_defaults", unique: true, where: "(project_id IS NULL)"
    t.index ["account_id"], name: "index_quality_thresholds_on_account_id"
    t.index ["project_id", "metric_type", "goal_type"], name: "index_quality_thresholds_on_project_overrides", unique: true, where: "(project_id IS NOT NULL)"
    t.index ["project_id"], name: "index_quality_thresholds_on_project_id"
  end

  create_table "remediation_decisions", comment: "Audits self-heal diagnoses and proposed remediation actions for recurring agent-run failure fingerprints.", force: :cascade do |t|
    t.bigint "account_id", null: false, comment: "Owning account for tenant isolation and auditing."
    t.string "action_target_id", comment: "Opaque target identifier for the proposed action."
    t.jsonb "action_target_metadata", default: {}, null: false, comment: "Extra target details such as a runner field name."
    t.string "action_target_type", null: false, comment: "Normalized target category such as account, project, runner, or runner_field."
    t.datetime "applied_at", comment: "When the remediation action was applied."
    t.bigint "applied_by_id", comment: "User who approved or applied the action when it was manual."
    t.decimal "confidence", precision: 4, scale: 3, default: "0.0", null: false, comment: "Model confidence score from 0.0 to 1.0 for the proposed action."
    t.datetime "created_at", null: false
    t.integer "diagnosis_attempt_count_on_day", default: 1, null: false, comment: "How many diagnosis attempts for this fingerprint consumed budget on diagnosis_attempted_on."
    t.date "diagnosis_attempted_on", comment: "UTC day when this fingerprint last consumed diagnosis budget."
    t.jsonb "evidence_pointers", default: [], null: false, comment: "Pointers into the sanitized evidence bundle that support the diagnosis."
    t.string "fingerprint", null: false, comment: "Stable pattern fingerprint used to dedupe recurring diagnoses."
    t.datetime "last_diagnosis_attempt_at", comment: "Timestamp of the most recent diagnosis attempt recorded for this audit row."
    t.integer "occurrence_count", default: 1, null: false, comment: "How many detections collapsed into this deduped decision row."
    t.string "outcome", comment: "Evaluation result for the remediation: improved, unchanged, or regressed."
    t.integer "post_remediation_failure_count", comment: "Observed failure count for the fingerprint after remediation evaluation."
    t.integer "pre_remediation_failure_count", comment: "Observed failure count for the fingerprint before remediation was proposed."
    t.string "proposed_action", null: false, comment: "Frozen action enum proposed by the diagnosis pipeline."
    t.jsonb "revert_data", default: {}, null: false, comment: "Structured data needed to reverse an applied remediation unambiguously."
    t.text "root_cause", null: false, comment: "Human-readable diagnosis summary shown in notifications and audits."
    t.string "status", default: "proposed", null: false, comment: "Lifecycle state: proposed, approved, applied, skipped, failed, or reverted."
    t.datetime "updated_at", null: false
    t.index ["account_id", "diagnosis_attempted_on"], name: "idx_remediation_decisions_budget_lookup"
    t.index ["account_id", "fingerprint", "created_at"], name: "idx_remediation_decisions_dedup_lookup"
    t.index ["account_id", "status", "created_at"], name: "idx_remediation_decisions_account_status_created"
    t.index ["account_id"], name: "index_remediation_decisions_on_account_id"
    t.index ["applied_by_id"], name: "index_remediation_decisions_on_applied_by_id"
    t.index ["proposed_action"], name: "index_remediation_decisions_on_proposed_action"
  end

  create_table "roi_benchmarks", comment: "Customer-specific comparison baselines used in ROI dashboards and pilot reports.", force: :cascade do |t|
    t.integer "accepted_pr_count", default: 0, null: false, comment: "Accepted pull requests included in this benchmark window."
    t.decimal "average_cycle_time_hours", precision: 10, scale: 2, comment: "Average elapsed hours from issue intake to accepted pull request."
    t.string "benchmark_type", limit: 50, null: false, comment: "Supported comparison class: human_only or commercial_agent."
    t.integer "cost_per_accepted_pr_cents", comment: "Blended cost for each accepted pull request in cents."
    t.datetime "created_at", null: false
    t.decimal "defect_escape_rate", precision: 5, scale: 2, comment: "Share of accepted pull requests followed by post-acceptance fix work, stored as a percentage."
    t.datetime "ends_at", comment: "Inclusive end of the benchmark measurement window."
    t.decimal "merge_rate", precision: 5, scale: 2, comment: "Accepted pull requests divided by created pull requests, stored as a percentage."
    t.string "name", limit: 255, null: false, comment: "Human-readable benchmark label such as Human-only Baseline or Cursor Pilot."
    t.text "notes", comment: "Free-form implementation notes captured for stakeholder review."
    t.bigint "project_id", null: false, comment: "Owning project for tenant isolation and benchmark segmentation."
    t.decimal "rework_rate", precision: 5, scale: 2, comment: "Share of accepted pull requests requiring follow-up work, stored as a percentage."
    t.datetime "starts_at", comment: "Inclusive start of the benchmark measurement window."
    t.string "tool_name", limit: 100, comment: "Specific vendor or tool name when benchmark_type is commercial_agent."
    t.datetime "updated_at", null: false
    t.index ["project_id", "benchmark_type", "ends_at"], name: "idx_roi_benchmarks_project_type_ends_at"
    t.index ["project_id", "name"], name: "idx_roi_benchmarks_project_name"
  end

  create_table "runner_auth_attempts", comment: "Structured telemetry for runner subscription-auth attempts, used to compare managed RunnerCredential auth with legacy host-mounted local auth before remote cutover (RDR-041 / #2960).", force: :cascade do |t|
    t.bigint "account_id", null: false, comment: "Owning account; denormalized for account-scoped analytics and reporting."
    t.bigint "agent_run_id", comment: "Agent run that triggered this attempt, when the attempt is bound to a run."
    t.string "attempt_stage", limit: 32, null: false, comment: "Lifecycle stage of the attempt: materialization, refresh, lease, harvest, eligibility."
    t.datetime "attempted_at", null: false, comment: "When the attempt occurred; mirrors created_at but is set explicitly so background recorders can write back-dated rows when telemetry is flushed after the real attempt."
    t.string "auth_source", limit: 32, null: false, comment: "Resolved auth source: managed, host_forwarded, api_key_proxy, none."
    t.boolean "backend_remote", comment: "Whether the resolved backend was remote at attempt time."
    t.boolean "backend_supports_host_paths", comment: "Whether the resolved backend supports host bind mounts at attempt time."
    t.string "container_host", limit: 64, comment: "Container backend identifier that the attempt was bound to."
    t.datetime "created_at", null: false
    t.integer "duration_ms", comment: "Wall-clock duration of the attempt in milliseconds, when measurable."
    t.string "failure_reason", limit: 64, comment: "UI-safe failure reason code (e.g. credential_expired, refresh_token_reused)."
    t.string "feature_flag_state", limit: 32, comment: "State of the managed_subscription_runner_auth flag: enabled, disabled, unregistered."
    t.string "lease_state", limit: 32, comment: "Lease outcome: none, acquired, waited, timeout, not_applicable."
    t.string "materialization_mode", limit: 32, comment: "Materializer mode: env, native_file, broker, host_mount, unsupported."
    t.jsonb "metadata", default: {}, null: false, comment: "Non-secret contextual fields such as feature-flag rollout and materializer rotation risk."
    t.bigint "project_id", null: false, comment: "Owning project; mirrors the agent_run linkage for tenant-isolated reporting."
    t.string "refresh_state", limit: 32, comment: "Refresh outcome: not_needed, refreshed, refresh_failed, expired, not_applicable."
    t.string "result", limit: 32, null: false, comment: "Final attempt outcome: materialized, skipped, failed, harvested, harvest_failed, refreshed, refresh_failed, expired, lease_acquired, lease_timeout."
    t.integer "retry_count", default: 0, null: false, comment: "Number of retries performed before recording this attempt outcome."
    t.bigint "runner_credential_id", comment: "RunnerCredential record the attempt used, when the attempt is managed."
    t.string "runner_key", limit: 64, null: false, comment: "Provider key (claude, codex, gemini, copilot)."
    t.datetime "updated_at", null: false
    t.index ["account_id", "attempted_at"], name: "idx_runner_auth_attempts_account_attempted"
    t.index ["account_id"], name: "index_runner_auth_attempts_on_account_id"
    t.index ["agent_run_id", "attempt_stage", "attempted_at"], name: "idx_runner_auth_attempts_run_stage_attempted"
    t.index ["agent_run_id"], name: "index_runner_auth_attempts_on_agent_run_id"
    t.index ["attempt_stage", "result", "attempted_at"], name: "idx_runner_auth_attempts_stage_result_attempted"
    t.index ["project_id", "attempted_at"], name: "idx_runner_auth_attempts_project_attempted"
    t.index ["project_id"], name: "index_runner_auth_attempts_on_project_id"
    t.index ["result", "attempted_at"], name: "idx_runner_auth_attempts_result_attempted"
    t.index ["runner_credential_id"], name: "index_runner_auth_attempts_on_runner_credential_id"
    t.index ["runner_key", "auth_source", "container_host", "attempted_at"], name: "idx_runner_auth_attempts_provider_source_host_attempted"
  end

  create_table "runner_credentials", comment: "Account-scoped encrypted credentials for subscription runners (Claude Code, Codex, Gemini, Copilot)", force: :cascade do |t|
    t.bigint "account_id", null: false, comment: "Account that owns this credential"
    t.string "auth_kind", default: "oauth_token", null: false, comment: "Authentication mechanism (oauth_token, api_key, signing_token)"
    t.datetime "created_at", null: false
    t.bigint "created_by_id", comment: "User who created the credential"
    t.datetime "expires_at", comment: "Token expiry time; nil means no expiry"
    t.datetime "last_used_at", comment: "Last time this credential was injected into a container"
    t.jsonb "log_data"
    t.boolean "long_lived", default: false, null: false, comment: "When true, skips expiry tracking and refresh (e.g. claude setup-token)"
    t.jsonb "metadata", default: {}, null: false, comment: "Arbitrary provider-specific metadata"
    t.string "name", null: false, comment: "Human-readable label for this credential"
    t.datetime "revoked_at", comment: "Set when credential is revoked; nil means active"
    t.string "runner_key", null: false, comment: "Runner provider key (e.g. claude, codex, gemini, copilot)"
    t.text "token", null: false, comment: "Encrypted credential token"
    t.datetime "updated_at", null: false
    t.index ["account_id", "revoked_at"], name: "index_runner_credentials_on_account_id_and_revoked_at"
    t.index ["account_id", "runner_key", "name"], name: "idx_runner_credentials_on_account_runner_key_name", unique: true
    t.index ["account_id", "runner_key"], name: "index_runner_credentials_on_account_id_and_runner_key"
    t.index ["account_id"], name: "index_runner_credentials_on_account_id"
    t.index ["created_by_id"], name: "index_runner_credentials_on_created_by_id"
  end

  create_table "runner_states", force: :cascade do |t|
    t.datetime "circuit_opened_at"
    t.string "circuit_state", limit: 20, default: "closed", null: false
    t.datetime "created_at", null: false
    t.integer "failure_count", default: 0, null: false
    t.integer "half_open_failure_count", default: 0, null: false, comment: "Consecutive failures observed while the circuit is half-open."
    t.integer "half_open_success_count", default: 0, null: false, comment: "Consecutive successes observed while the circuit is half-open."
    t.datetime "last_failure_at", comment: "Timestamp of the most recent runner failure used to decay stale circuit-breaker failures."
    t.jsonb "metadata", default: {}, null: false, comment: "Free-form metadata. Currently stores per-model rate-limit windows under the 'rate_limited_models' key so the openrouter_free runner can rotate past a rate-limited model without resetting the whole runner."
    t.datetime "rate_limited_until"
    t.string "runner_name", limit: 50, null: false
    t.datetime "updated_at", null: false
    t.bigint "user_id", null: false
    t.index ["user_id", "runner_name"], name: "index_runner_states_on_user_id_and_runner_name", unique: true
  end

  create_table "runners", force: :cascade do |t|
    t.text "agent_co_author_trailer"
    t.string "auth_type", limit: 20, default: "subscription", null: false
    t.jsonb "complexity_thresholds", default: {"low_max" => 3, "mid_max" => 7}, null: false
    t.jsonb "config", default: {}, null: false
    t.datetime "created_at", null: false
    t.datetime "discarded_at", comment: "Soft-delete timestamp so historical provider names remain available for filters and run history."
    t.boolean "enabled_for_agent_runs", default: true, null: false
    t.boolean "enabled_for_chat", default: true, null: false, comment: "Whether the runner is eligible to back interactive chat sessions."
    t.boolean "enabled_for_fallback", default: true, null: false
    t.string "fallback_role", limit: 30, default: "standard", null: false
    t.bigint "integration_credential_id"
    t.jsonb "log_data"
    t.integer "monthly_token_budget", comment: "Optional per-runner monthly token budget used to auto-balance API-key runner weights. Null means unlimited or unknown."
    t.string "name", limit: 100, default: "", null: false
    t.jsonb "no_progress_thresholds", default: {"min_input_tokens" => 100000, "max_output_tokens" => 100}, null: false, comment: "Per-runner thresholds for no-progress early termination. min_input_tokens: minimum input tokens consumed before checking; max_output_tokens: maximum output tokens that qualifies as no progress."
    t.bigint "provider_api_key_id"
    t.string "provider_key", limit: 50
    t.string "runner_key", limit: 50, null: false
    t.jsonb "tier_model_ids", comment: "Per-tier model mapping for configurable runners. Nil means no explicit mapping is stored."
    t.jsonb "tier_models", default: {}, null: false, comment: "Per-tier model map shared by Runner and Provider records on this table. Shape: {\"low\":{\"model_id\":\"model-id\",\"provider_id\":123}} keyed by LlmModel tiers."
    t.jsonb "time_restrictions", comment: "Per-runner time-window usage restrictions. Null means no restrictions. Shape: { mode: block|deprioritize, timezone: IANA zone, windows: [{ start_hour, end_hour }] }"
    t.datetime "updated_at", null: false
    t.bigint "user_id", null: false
    t.integer "weight", default: 1, null: false
    t.index ["auth_type"], name: "index_runners_on_auth_type"
    t.index ["discarded_at"], name: "index_runners_on_discarded_at"
    t.index ["integration_credential_id"], name: "index_runners_on_integration_credential_id"
    t.index ["provider_api_key_id"], name: "index_runners_on_provider_api_key_id"
    t.index ["tier_model_ids"], name: "index_runners_on_tier_model_ids", using: :gin
    t.index ["user_id", "provider_key", "provider_api_key_id", "name"], name: "idx_providers_unique_api_key", unique: true, where: "(((auth_type)::text = 'api_key'::text) AND (discarded_at IS NULL))"
    t.index ["user_id", "provider_key"], name: "idx_providers_unique_subscription", unique: true, where: "(((auth_type)::text = 'subscription'::text) AND (discarded_at IS NULL))"
    t.index ["user_id", "runner_key", "provider_api_key_id", "name"], name: "idx_runners_unique_api_key", unique: true, where: "(((auth_type)::text = 'api_key'::text) AND (discarded_at IS NULL))"
    t.index ["user_id", "runner_key"], name: "idx_runners_unique_subscription", unique: true, where: "(((auth_type)::text = 'subscription'::text) AND (discarded_at IS NULL))"
    t.index ["user_id"], name: "index_runners_on_user_id"
    t.check_constraint "auth_type::text <> 'api_key'::text OR provider_api_key_id IS NOT NULL OR integration_credential_id IS NOT NULL OR discarded_at IS NOT NULL", name: "runners_api_key_requires_key"
    t.check_constraint "auth_type::text <> 'subscription'::text OR provider_api_key_id IS NULL AND integration_credential_id IS NULL AND fallback_role::text = 'standard'::text", name: "runners_subscription_invariants"
    t.check_constraint "weight >= 1", name: "runners_weight_positive"
  end

  create_table "scaling_experiment_assignments", comment: "Workflow-scoped assignments and result snapshots for scaling experiments.", force: :cascade do |t|
    t.integer "assigned_value", null: false, comment: "Experiment arm chosen for the workflow, such as the requested agent count cap."
    t.datetime "created_at", null: false
    t.jsonb "execution_plan", default: {}, null: false, comment: "Structured execution plan describing how the assigned arm should be applied safely."
    t.bigint "issue_id", comment: "Parent feature issue whose orchestration workflow was assigned."
    t.string "outcome_status", limit: 50, default: "assigned", null: false, comment: "Capture state for the assignment: assigned, recorded, or skipped."
    t.jsonb "outcome_summary", default: {}, null: false, comment: "Normalized snapshot of the resulting observation for downstream analysis services."
    t.bigint "project_id", null: false, comment: "Owning project copied onto the assignment to simplify isolation and queries."
    t.bigint "scaling_experiment_id", null: false, comment: "Parent scaling experiment for this assignment."
    t.bigint "scaling_observation_id", comment: "Captured observation recorded for this assigned workflow once execution completes."
    t.datetime "updated_at", null: false
    t.string "workflow_id", limit: 255, null: false, comment: "Temporal workflow ID used as the stable experiment sample identifier."
    t.index ["project_id", "created_at"], name: "idx_scaling_experiment_assignments_project_recent"
    t.index ["project_id", "outcome_status", "created_at"], name: "idx_scaling_experiment_assignments_project_status"
    t.index ["scaling_experiment_id", "workflow_id"], name: "idx_scaling_experiment_assignments_unique", unique: true
    t.index ["scaling_observation_id"], name: "idx_scaling_experiment_assignments_observation", where: "(scaling_observation_id IS NOT NULL)"
  end

  create_table "scaling_experiments", comment: "Controlled orchestration experiments for measuring how feature outcomes change as the agent count changes.", force: :cascade do |t|
    t.jsonb "cached_summary", default: {}, null: false, comment: "Persisted descriptive summary for later analysis services and polling UIs."
    t.jsonb "cohort_settings", default: {}, null: false, comment: "Scheduling and labeling rules for experiment cohorts, such as task buckets and label templates."
    t.datetime "completed_at", comment: "Timestamp when the experiment stopped collecting data."
    t.jsonb "context_filter", default: {}, null: false, comment: "Eligibility filter for safely including only comparable workflows in the experiment."
    t.jsonb "control_definition", default: {}, null: false, comment: "Control conditions and fairness guardrails that must hold for cohort-to-cohort comparisons."
    t.integer "control_value", null: false, comment: "Baseline arm used as the control when comparing experiment results."
    t.datetime "created_at", null: false
    t.string "dimension", limit: 50, default: "agent_count", null: false, comment: "Scaling dimension under test. Agent count is the initial supported dimension."
    t.text "hypothesis", null: false, comment: "Expected scaling behavior being tested, such as diminishing returns after a certain agent count."
    t.jsonb "independent_variables", default: [], null: false, comment: "Declared primary and contextual variables for the controlled scaling plan, including the tested arm values."
    t.integer "min_samples_per_value", default: 2, null: false, comment: "Minimum number of recorded workflows required for each tested value before the experiment can complete."
    t.string "name", limit: 255, null: false, comment: "Human-readable experiment name displayed in dashboards and logs."
    t.jsonb "outcome_metrics", default: [], null: false, comment: "Outcome metrics tracked for the experiment plan, including optimization direction and primary-vs-guardrail roles."
    t.bigint "project_id", null: false, comment: "Owning project for tenant isolation and experiment segmentation."
    t.datetime "started_at", comment: "Timestamp when the experiment started assigning workflows."
    t.string "status", limit: 50, default: "draft", null: false, comment: "Lifecycle state for the experiment: draft, running, completed, or cancelled."
    t.string "summary_samples_key", comment: "Cache key derived from per-arm sample counts so summaries can be reused until data changes."
    t.integer "traffic_percentage", default: 100, null: false, comment: "Percent of eligible workflows allowed into the experiment."
    t.datetime "updated_at", null: false
    t.jsonb "values_tested", default: [], null: false, comment: "Ordered list of experiment arms, such as [1, 2, 4], for the tested dimension."
    t.index ["project_id", "dimension", "status"], name: "idx_scaling_experiments_project_dimension_status"
    t.index ["project_id", "dimension"], name: "idx_scaling_experiments_one_running_dimension", unique: true, where: "((status)::text = 'running'::text)"
  end

  create_table "scaling_observations", comment: "Run-level observations for studying orchestration scaling behavior across agent count, iterations, and parallelism.", force: :cascade do |t|
    t.integer "agent_count_blocked", default: 0, null: false, comment: "Number of planned tasks that never launched because of dependencies, deadlines, or capacity."
    t.integer "agent_count_failed", default: 0, null: false, comment: "Number of launched child agent runs that completed unsuccessfully."
    t.integer "agent_count_launched", default: 0, null: false, comment: "Number of child agent runs actually launched."
    t.integer "agent_count_planned", default: 0, null: false, comment: "Number of agents the orchestration planned to use."
    t.integer "agent_count_succeeded", default: 0, null: false, comment: "Number of launched child agent runs that completed successfully."
    t.integer "batch_count", default: 0, null: false, comment: "Number of execution batches used by the parallel workflow."
    t.datetime "created_at", null: false
    t.integer "dependency_edge_count", default: 0, null: false, comment: "Total dependency edges across planned sub-tasks."
    t.integer "duration_seconds", comment: "Elapsed wall-clock seconds for the orchestration workflow."
    t.bigint "issue_id", comment: "Parent feature issue whose orchestration emitted the observation."
    t.integer "max_iterations", default: 0, null: false, comment: "Maximum iterations observed on any launched child agent run."
    t.jsonb "metadata", default: {}, null: false, comment: "Structured detail for experiments, including batch sizes, errors, and linked child runs."
    t.string "observation_type", limit: 100, default: "feature_orchestration", null: false, comment: "Observation category used to group comparable orchestration runs."
    t.boolean "parallel_execution", default: false, null: false, comment: "Whether the workflow attempted parallel child execution."
    t.integer "parallelism_observed", default: 0, null: false, comment: "Maximum child workflow batch size actually launched concurrently."
    t.integer "parallelism_planned", default: 0, null: false, comment: "Maximum planned same-wave task count from decomposition parallel groups."
    t.integer "parallelizable_group_count", default: 0, null: false, comment: "Count of planned parallel groups containing more than one task."
    t.bigint "project_id", null: false, comment: "Owning project for tenant isolation and experiment segmentation."
    t.string "status", limit: 100, default: "completed", null: false, comment: "Terminal orchestration outcome such as completed, skipped, no_capacity, partial_failure, or failed."
    t.boolean "success", default: false, null: false, comment: "Whether the orchestration run achieved its intended terminal outcome."
    t.integer "task_count", default: 0, null: false, comment: "Number of planned sub-tasks in the decomposition."
    t.integer "total_cost_cents", default: 0, null: false, comment: "Sum of cost_cents across launched child agent runs."
    t.integer "total_input_tokens", default: 0, null: false, comment: "Sum of input tokens across launched child agent runs."
    t.integer "total_iterations", default: 0, null: false, comment: "Sum of iterations across launched child agent runs."
    t.integer "total_output_tokens", default: 0, null: false, comment: "Sum of output tokens across launched child agent runs."
    t.datetime "updated_at", null: false
    t.string "workflow_id", limit: 255, null: false, comment: "Temporal workflow ID for the orchestration run."
    t.string "workflow_name", limit: 255, null: false, comment: "Workflow class that emitted the observation."
    t.index ["issue_id", "created_at"], name: "idx_scaling_observations_issue_created"
    t.index ["project_id", "created_at", "id"], name: "idx_scaling_observations_project_recent"
    t.index ["project_id", "observation_type", "created_at"], name: "idx_scaling_observations_project_type_created"
    t.index ["project_id", "status", "created_at"], name: "idx_scaling_observations_project_status_created"
    t.index ["project_id", "workflow_id"], name: "idx_scaling_observations_project_workflow", unique: true
  end

  create_table "service_container_metrics", force: :cascade do |t|
    t.string "container_id", limit: 128, null: false
    t.float "cpu_percent", default: 0.0, null: false
    t.datetime "created_at", null: false
    t.bigint "memory_bytes", default: 0, null: false
    t.bigint "memory_limit_bytes", default: 0, null: false
    t.float "memory_percent", default: 0.0, null: false
    t.integer "pids_count"
    t.datetime "recorded_at", null: false
    t.bigint "service_container_id", null: false
    t.datetime "updated_at", null: false
    t.index ["container_id"], name: "index_service_container_metrics_on_container_id"
    t.index ["recorded_at"], name: "index_service_container_metrics_on_recorded_at"
    t.index ["service_container_id", "recorded_at"], name: "index_service_container_metrics_on_container_and_recorded"
    t.index ["service_container_id"], name: "index_service_container_metrics_on_service_container_id"
  end

  create_table "service_containers", force: :cascade do |t|
    t.bigint "account_id", null: false
    t.float "avg_cpu_percent"
    t.decimal "avg_memory_bytes", precision: 20, scale: 4
    t.string "container_host", limit: 64, comment: "Container backend host identifier that currently owns the running service container."
    t.integer "container_metrics_count", default: 0, null: false
    t.datetime "created_at", null: false
    t.string "docker_container_id"
    t.jsonb "env", default: {}
    t.string "image", null: false
    t.jsonb "log_data"
    t.string "name", null: false
    t.float "peak_cpu_percent"
    t.bigint "peak_memory_bytes"
    t.integer "port", null: false
    t.string "status", default: "stopped", null: false
    t.datetime "updated_at", null: false
    t.index ["account_id", "name"], name: "index_service_containers_on_account_id_and_name", unique: true
    t.index ["account_id"], name: "index_service_containers_on_account_id"
  end

  create_table "strategies", comment: "Scoped orchestration strategies selected for workflow decisions.", force: :cascade do |t|
    t.bigint "account_id", comment: "Owning account for account-scoped and project-scoped strategies."
    t.datetime "created_at", null: false
    t.bigint "current_version_id", comment: "Currently promoted strategy version used by selection."
    t.string "decision_type", limit: 100, null: false, comment: "Workflow decision boundary this strategy governs, such as issue_execution or retry."
    t.text "description", comment: "Optional description of when and why this strategy should be selected."
    t.string "name", limit: 255, null: false, comment: "Human-readable strategy name."
    t.bigint "project_id", comment: "Owning project for project-specific strategy overrides."
    t.jsonb "selection_rules", default: {}, null: false, comment: "Structured scope and context rules used to select the strategy."
    t.string "slug", limit: 100, null: false, comment: "Stable identifier used to resolve a strategy within its scope."
    t.string "status", limit: 20, default: "active", null: false, comment: "Lifecycle state controlling whether the strategy is eligible for selection."
    t.datetime "updated_at", null: false
    t.index ["account_id"], name: "index_strategies_on_account_id"
    t.index ["current_version_id"], name: "index_strategies_on_current_version_id"
    t.index ["decision_type", "status"], name: "index_strategies_on_decision_type_and_status"
    t.index ["decision_type"], name: "index_strategies_on_decision_type"
    t.index ["project_id"], name: "index_strategies_on_project_id"
    t.index ["slug", "account_id"], name: "index_strategies_on_slug_account", unique: true, where: "((account_id IS NOT NULL) AND (project_id IS NULL))"
    t.index ["slug", "project_id"], name: "index_strategies_on_slug_project", unique: true, where: "(project_id IS NOT NULL)"
    t.index ["slug"], name: "index_strategies_on_slug_global", unique: true, where: "((account_id IS NULL) AND (project_id IS NULL))"
    t.index ["status"], name: "index_strategies_on_status"
    t.check_constraint "project_id IS NULL OR account_id IS NOT NULL", name: "chk_strategies_scope_consistency"
  end

  create_table "strategy_experiment_assignments", comment: "Maps each agent run to the strategy variant it was assigned", force: :cascade do |t|
    t.bigint "agent_run_id", null: false
    t.datetime "created_at", null: false
    t.decimal "quality_score", precision: 5, scale: 4
    t.bigint "strategy_experiment_id", null: false
    t.bigint "strategy_experiment_variant_id", null: false
    t.datetime "updated_at", null: false
    t.index ["agent_run_id"], name: "index_strategy_experiment_assignments_on_agent_run_id"
    t.index ["strategy_experiment_id", "agent_run_id"], name: "index_strategy_experiment_assignments_unique", unique: true
    t.index ["strategy_experiment_variant_id"], name: "idx_on_strategy_experiment_variant_id_95cba2d3c7"
  end

  create_table "strategy_experiment_variants", comment: "Individual variant arms within a strategy A/B test", force: :cascade do |t|
    t.decimal "avg_quality_score", precision: 5, scale: 4
    t.datetime "created_at", null: false
    t.boolean "is_control", default: false, null: false
    t.integer "sample_count", default: 0, null: false
    t.text "strategy_config", null: false, comment: "JSON-encoded configuration for this variant"
    t.bigint "strategy_experiment_id", null: false
    t.decimal "total_quality_score", precision: 10, scale: 4, default: "0.0", null: false
    t.datetime "updated_at", null: false
    t.index ["strategy_experiment_id", "is_control"], name: "index_strategy_experiment_variants_on_experiment_control"
    t.index ["strategy_experiment_id"], name: "index_strategy_experiment_variants_one_control", unique: true, where: "(is_control = true)"
  end

  create_table "strategy_experiments", comment: "A/B tests comparing evolved automation strategy variants against a baseline", force: :cascade do |t|
    t.bigint "account_id", null: false
    t.string "analysis_samples_key"
    t.jsonb "cached_analysis"
    t.datetime "completed_at"
    t.decimal "confidence_threshold", precision: 5, scale: 4, default: "0.95", null: false
    t.text "control_config", null: false, comment: "JSON-encoded baseline configuration for the strategy"
    t.datetime "created_at", null: false
    t.text "description"
    t.string "idempotency_key"
    t.integer "min_samples_per_variant", default: 30, null: false
    t.string "name", null: false
    t.datetime "started_at"
    t.string "status", limit: 50, default: "draft", null: false
    t.string "strategy_name", limit: 100, null: false, comment: "Automation strategy being tested (e.g. auto_pick, auto_review)"
    t.integer "traffic_percentage", default: 100, null: false
    t.datetime "updated_at", null: false
    t.bigint "winner_variant_id"
    t.index ["account_id", "strategy_name", "idempotency_key"], name: "index_strategy_experiments_on_idempotency_key", unique: true, where: "(idempotency_key IS NOT NULL)"
    t.index ["account_id", "strategy_name", "status"], name: "index_strategy_experiments_on_account_strategy_status"
    t.index ["account_id", "strategy_name"], name: "index_strategy_experiments_one_running_per_account_strategy", unique: true, where: "((status)::text = 'running'::text)"
    t.index ["winner_variant_id"], name: "index_strategy_experiments_on_winner_variant_id"
  end

  create_table "strategy_versions", comment: "Versioned orchestration strategy payloads and promotion history.", force: :cascade do |t|
    t.text "change_notes", comment: "Operator- or workflow-authored notes about the change."
    t.jsonb "content", default: {}, null: false, comment: "Structured orchestration behavior moved out of hardcoded workflow logic."
    t.datetime "created_at", null: false
    t.string "created_by", limit: 50, comment: "Origin label such as seed, human, or evolution."
    t.bigint "created_by_user_id", comment: "User who created the version when applicable."
    t.bigint "parent_version_id", comment: "Previous version this candidate was derived from."
    t.datetime "promoted_at", comment: "When this version became current."
    t.bigint "promoted_by_user_id", comment: "User who promoted this version to current."
    t.string "promotion_state", limit: 20, default: "draft", null: false, comment: "Promotion lifecycle state for this version."
    t.jsonb "provenance", default: {}, null: false, comment: "Origin metadata such as manual creation, evolution run, or experiment lineage."
    t.text "reasoning", comment: "Why this version exists or differs from its parent."
    t.datetime "retired_at", comment: "When this version stopped being eligible for execution."
    t.bigint "strategy_id", null: false, comment: "Parent strategy whose behavior this version defines."
    t.datetime "updated_at", null: false
    t.integer "version", null: false, comment: "Monotonic version number within a strategy."
    t.index ["created_by_user_id"], name: "index_strategy_versions_on_created_by_user_id"
    t.index ["parent_version_id"], name: "index_strategy_versions_on_parent_version_id"
    t.index ["promoted_by_user_id"], name: "index_strategy_versions_on_promoted_by_user_id"
    t.index ["retired_at"], name: "index_strategy_versions_on_retired_at"
    t.index ["strategy_id", "promotion_state"], name: "index_strategy_versions_on_strategy_and_promotion_state"
    t.index ["strategy_id", "version"], name: "index_strategy_versions_on_strategy_id_and_version", unique: true
    t.index ["strategy_id"], name: "index_strategy_versions_on_strategy_id"
    t.index ["strategy_id"], name: "index_strategy_versions_one_active_per_strategy", unique: true, where: "(((promotion_state)::text = 'active'::text) AND (retired_at IS NULL))"
  end

  create_table "style_guide_ab_test_assignments", force: :cascade do |t|
    t.bigint "agent_run_id", null: false
    t.datetime "created_at", null: false
    t.decimal "quality_score", precision: 5, scale: 4
    t.bigint "style_guide_ab_test_id", null: false
    t.bigint "style_guide_ab_test_variant_id", null: false
    t.datetime "updated_at", null: false
    t.index ["agent_run_id"], name: "index_style_guide_ab_test_assignments_on_agent_run_id"
    t.index ["style_guide_ab_test_id", "agent_run_id"], name: "index_style_guide_ab_test_assignments_unique", unique: true
    t.index ["style_guide_ab_test_id"], name: "idx_on_style_guide_ab_test_id_653b807c99"
    t.index ["style_guide_ab_test_variant_id"], name: "idx_on_style_guide_ab_test_variant_id_6da5a7dee2"
  end

  create_table "style_guide_ab_test_variants", force: :cascade do |t|
    t.decimal "avg_quality_score", precision: 5, scale: 4
    t.datetime "created_at", null: false
    t.boolean "is_control", default: false, null: false
    t.integer "sample_count", default: 0, null: false
    t.bigint "style_guide_ab_test_id", null: false
    t.bigint "style_guide_version_id", null: false
    t.decimal "total_quality_score", precision: 10, scale: 4, default: "0.0", null: false
    t.datetime "updated_at", null: false
    t.index ["style_guide_ab_test_id", "style_guide_version_id"], name: "index_style_guide_ab_test_variants_on_test_and_version", unique: true
    t.index ["style_guide_ab_test_id"], name: "index_style_guide_ab_test_variants_on_control_per_test", unique: true, where: "(is_control = true)"
    t.index ["style_guide_ab_test_id"], name: "index_style_guide_ab_test_variants_on_style_guide_ab_test_id"
    t.index ["style_guide_version_id"], name: "index_style_guide_ab_test_variants_on_style_guide_version_id"
  end

  create_table "style_guide_ab_tests", force: :cascade do |t|
    t.bigint "account_id", null: false
    t.string "analysis_samples_key"
    t.jsonb "cached_analysis"
    t.datetime "completed_at"
    t.decimal "confidence_threshold", default: "0.95", null: false
    t.bigint "control_version_id", null: false
    t.datetime "created_at", null: false
    t.text "description"
    t.string "idempotency_key"
    t.integer "min_samples_per_variant", default: 30, null: false
    t.string "name", null: false
    t.datetime "started_at"
    t.string "status", default: "draft", null: false
    t.bigint "style_guide_id", null: false
    t.datetime "updated_at", null: false
    t.bigint "winner_variant_id"
    t.index ["account_id"], name: "index_style_guide_ab_tests_on_account_id"
    t.index ["account_id"], name: "index_style_guide_ab_tests_one_running_per_account", unique: true, where: "((status)::text = 'running'::text)"
    t.index ["control_version_id"], name: "index_style_guide_ab_tests_on_control_version_id"
    t.index ["status"], name: "index_style_guide_ab_tests_on_status"
    t.index ["style_guide_id", "idempotency_key"], name: "idx_on_style_guide_id_idempotency_key_e10519ccd2", unique: true, where: "(idempotency_key IS NOT NULL)"
    t.index ["style_guide_id", "status"], name: "index_style_guide_ab_tests_on_style_guide_id_and_status"
    t.index ["style_guide_id"], name: "index_style_guide_ab_tests_on_style_guide_id"
    t.index ["winner_variant_id"], name: "index_style_guide_ab_tests_on_winner_variant_id"
  end

  create_table "style_guide_run_exposures", force: :cascade do |t|
    t.bigint "agent_run_id", null: false
    t.datetime "created_at", null: false
    t.string "guide_name", null: false
    t.text "injected_content"
    t.string "injected_via", limit: 50, null: false
    t.integer "position", null: false
    t.string "source_scope", limit: 20, null: false
    t.bigint "style_guide_ab_test_assignment_id"
    t.bigint "style_guide_id"
    t.bigint "style_guide_version_id", null: false
    t.datetime "updated_at", null: false
    t.index ["agent_run_id", "guide_name"], name: "index_style_guide_run_exposures_on_run_and_name", unique: true
    t.index ["agent_run_id"], name: "index_style_guide_run_exposures_on_agent_run_id"
    t.index ["style_guide_ab_test_assignment_id"], name: "idx_on_style_guide_ab_test_assignment_id_d2bca3fb4e"
    t.index ["style_guide_ab_test_assignment_id"], name: "index_style_guide_run_exposures_on_assignment_id"
    t.index ["style_guide_id", "created_at"], name: "idx_on_style_guide_id_created_at_4675f78c23"
    t.index ["style_guide_id"], name: "index_style_guide_run_exposures_on_style_guide_id"
    t.index ["style_guide_version_id"], name: "index_style_guide_run_exposures_on_style_guide_version_id"
  end

  create_table "style_guide_versions", force: :cascade do |t|
    t.decimal "avg_quality_score", precision: 5, scale: 4
    t.text "change_notes"
    t.text "compressed_content"
    t.jsonb "compression_metadata", default: {}, null: false
    t.datetime "created_at", null: false
    t.string "created_by", limit: 50
    t.bigint "created_by_user_id"
    t.string "idempotency_key"
    t.bigint "parent_version_id"
    t.text "raw_content", null: false
    t.datetime "retired_at"
    t.text "review_notes"
    t.string "review_status", limit: 20
    t.datetime "reviewed_at"
    t.bigint "reviewed_by_user_id"
    t.bigint "style_guide_id", null: false
    t.datetime "updated_at", null: false
    t.integer "usage_count", default: 0, null: false
    t.integer "version", null: false
    t.index ["created_by_user_id"], name: "index_style_guide_versions_on_created_by_user_id"
    t.index ["parent_version_id"], name: "index_style_guide_versions_on_parent_version_id"
    t.index ["retired_at"], name: "index_style_guide_versions_on_retired_at"
    t.index ["reviewed_by_user_id"], name: "index_style_guide_versions_on_reviewed_by_user_id"
    t.index ["style_guide_id", "idempotency_key"], name: "idx_on_style_guide_id_idempotency_key_48d30b1e0e", unique: true, where: "(idempotency_key IS NOT NULL)"
    t.index ["style_guide_id", "review_status"], name: "index_style_guide_versions_on_style_guide_id_and_review_status"
    t.index ["style_guide_id", "version"], name: "index_style_guide_versions_on_style_guide_id_and_version", unique: true
    t.index ["style_guide_id"], name: "index_style_guide_versions_on_style_guide_id"
  end

  create_table "style_guides", force: :cascade do |t|
    t.bigint "account_id"
    t.boolean "active", default: true, null: false
    t.text "compressed_content"
    t.jsonb "compression_metadata", default: {}, null: false
    t.datetime "created_at", null: false
    t.bigint "current_version_id"
    t.string "language", limit: 50
    t.jsonb "log_data"
    t.string "name", limit: 255, null: false
    t.bigint "project_id"
    t.text "raw_content", null: false
    t.datetime "updated_at", null: false
    t.index ["account_id"], name: "index_style_guides_on_account_id"
    t.index ["active"], name: "index_style_guides_on_active"
    t.index ["current_version_id"], name: "index_style_guides_on_current_version_id"
    t.index ["language"], name: "index_style_guides_on_language"
    t.index ["name", "account_id"], name: "index_style_guides_on_name_account", unique: true, where: "((account_id IS NOT NULL) AND (project_id IS NULL))"
    t.index ["name", "project_id"], name: "index_style_guides_on_name_project", unique: true, where: "(project_id IS NOT NULL)"
    t.index ["name"], name: "index_style_guides_on_name_global", unique: true, where: "((account_id IS NULL) AND (project_id IS NULL))"
    t.index ["project_id"], name: "index_style_guides_on_project_id"
    t.check_constraint "project_id IS NULL OR account_id IS NOT NULL", name: "chk_style_guides_scope_consistency"
  end

  create_table "tenant_settings", force: :cascade do |t|
    t.bigint "account_id", null: false
    t.jsonb "agent_settings", default: {}, null: false
    t.text "allowed_runner_keys", default: [], array: true
    t.jsonb "auto_pick_skip_labels", comment: "Optional tenant-level override for labels that make auto-pick skip an issue. Null means use built-in defaults."
    t.datetime "created_at", null: false
    t.jsonb "default_budgets", default: {}, null: false
    t.string "docker_host_fallback_behavior", default: "disabled", null: false, comment: "Fallback behavior when the preferred Docker host is unavailable: disabled or first_healthy."
    t.jsonb "features", default: {}, null: false
    t.jsonb "guardrails", default: {}, null: false
    t.jsonb "log_data"
    t.integer "max_concurrent_create_pr_runs", default: 20, null: false, comment: "Account-level cap on concurrent create_pr agent runs to prevent success rate collapse at high concurrency"
    t.integer "max_concurrent_runs", default: 10, null: false
    t.integer "max_monthly_cost_cents"
    t.integer "max_projects", default: 50, null: false
    t.integer "max_tokens_per_run", default: 10000000, null: false
    t.integer "max_users", default: 25, null: false
    t.string "preferred_docker_host_identifier", comment: "Account-wide preferred Docker host identifier for manual placement defaults."
    t.jsonb "quality_thresholds", default: {}, null: false
    t.jsonb "runner_preferences", default: {}, null: false
    t.string "self_repo_full_name"
    t.datetime "updated_at", null: false
    t.jsonb "worker_settings", default: {}, null: false
    t.index ["account_id"], name: "index_tenant_settings_on_account_id", unique: true
  end

  create_table "token_usages", force: :cascade do |t|
    t.bigint "agent_run_id"
    t.bigint "chat_session_id"
    t.integer "cost_cents", default: 0, null: false
    t.datetime "created_at", null: false
    t.integer "input_tokens", default: 0, null: false
    t.bigint "knowledge_run_id"
    t.string "llm_model", limit: 100
    t.jsonb "metadata", default: {}, null: false
    t.integer "output_tokens", default: 0, null: false
    t.string "request_type", limit: 50, null: false
    t.datetime "updated_at", null: false
    t.index ["agent_run_id", "created_at"], name: "idx_token_usages_agent_run_created_at"
    t.index ["agent_run_id", "request_type"], name: "index_token_usages_on_agent_run_id_and_request_type"
    t.index ["chat_session_id"], name: "index_token_usages_on_chat_session_id"
    t.index ["created_at"], name: "index_token_usages_on_created_at"
    t.index ["knowledge_run_id", "created_at"], name: "idx_token_usages_knowledge_run_created_at"
    t.index ["knowledge_run_id"], name: "index_token_usages_on_knowledge_run_id"
    t.index ["llm_model"], name: "index_token_usages_on_llm_model"
    t.index ["request_type", "created_at"], name: "idx_token_usages_request_type_created_at"
    t.index ["request_type"], name: "index_token_usages_on_request_type"
    t.check_constraint "((agent_run_id IS NOT NULL)::integer + (knowledge_run_id IS NOT NULL)::integer + (chat_session_id IS NOT NULL)::integer) = 1", name: "token_usages_exactly_one_run"
  end

  create_table "tracker_configurations", comment: "Stores external issue-tracker integration settings for an account, user, or project.", force: :cascade do |t|
    t.string "base_url", comment: "Tracker base URL used when the integration targets a self-hosted or custom endpoint."
    t.bigint "configurable_id", null: false, comment: "Polymorphic owner id for the account, user, or project that owns the tracker configuration."
    t.string "configurable_type", null: false, comment: "Polymorphic owner type for the tracker configuration: Account, User, or Project."
    t.datetime "created_at", null: false
    t.bigint "created_by_id", comment: "User who created the tracker configuration."
    t.boolean "enabled", default: true, null: false, comment: "Whether this tracker configuration is active for automation."
    t.bigint "integration_credential_id", comment: "Credential used to authenticate to the external tracker when one is required."
    t.jsonb "log_data"
    t.jsonb "project_mapping", default: {}, comment: "Mapping data between Paid entities and tracker-specific project identifiers."
    t.string "tracker_type", null: false, comment: "External tracker implementation, such as github_issues, jira, linear, azure_devops, mcp, or generic_webhook."
    t.datetime "updated_at", null: false
    t.uuid "uuid", default: -> { "gen_random_uuid()" }, null: false
    t.index ["configurable_type", "configurable_id"], name: "index_tracker_configurations_on_configurable", unique: true
    t.index ["created_by_id"], name: "index_tracker_configurations_on_created_by_id"
    t.index ["integration_credential_id"], name: "index_tracker_configurations_on_integration_credential_id"
    t.index ["tracker_type"], name: "index_tracker_configurations_on_tracker_type"
    t.index ["uuid"], name: "index_tracker_configurations_on_uuid", unique: true
  end

  create_table "user_settings", force: :cascade do |t|
    t.integer "agent_timeout_seconds", default: 5400, null: false
    t.string "agent_update_comment_mode", default: "off", null: false, comment: "Controls whether existing-PR agent followups post no comment or generate a paid summary comment."
    t.jsonb "allowed_service_images", default: ["postgres:16.13", "redis:7-alpine", "selenium/standalone-chromium:latest"]
    t.jsonb "auto_pick_skip_labels", comment: "Optional user-level override for labels that make auto-pick skip an issue. Null means inherit tenant or built-in defaults."
    t.boolean "auto_weight_enabled", default: false, null: false, comment: "Whether automated runner weights are recalculated from observed remaining quota instead of edited manually."
    t.integer "circuit_breaker_failure_threshold", default: 5, null: false
    t.integer "circuit_breaker_timeout_seconds", default: 300, null: false
    t.bigint "container_memory_auto_ceiling_bytes", default: 17179869184, null: false, comment: "Upper bound (bytes) for the auto-tuned agent container memory limit so capacity-blocked workloads stop requesting unbounded memory."
    t.bigint "container_memory_auto_floor_bytes", default: 536870912, null: false, comment: "Lower bound (bytes) for the auto-tuned agent container memory limit so a sparse profile does not underprovision runs."
    t.bigint "container_memory_bytes", default: 4294967296, null: false
    t.string "container_memory_limit_mode", default: "manual", null: false, comment: "Whether agent container memory limits are taken from the fixed container_memory_bytes setting or from learned AgentRunResourceProfile recommendations."
    t.integer "container_timeout_seconds", default: 3600, null: false
    t.integer "create_pr_idle_timeout_seconds"
    t.datetime "created_at", null: false
    t.string "default_agent_runner", default: "claude", null: false
    t.jsonb "default_agent_runners_by_goal", default: {}, null: false
    t.jsonb "default_allowed_github_usernames", default: [], null: false
    t.boolean "default_auto_approve", default: true, null: false, comment: "Default value for the auto-approve actions checkbox when starting a new chat session"
    t.string "default_branch", default: "main", null: false
    t.integer "default_poll_interval_seconds", default: 60, null: false
    t.boolean "default_project_active", default: true, null: false
    t.boolean "fallback_enabled", default: false, null: false
    t.jsonb "fallback_runners", default: [], null: false
    t.integer "git_clone_timeout_seconds", default: 600, null: false
    t.integer "git_push_timeout_seconds", default: 60, null: false
    t.integer "git_unshallow_timeout_seconds", default: 1800, null: false
    t.integer "github_token_cache_ttl_minutes", default: 60, null: false
    t.integer "issue_goal_idle_timeout_seconds", default: 120, null: false
    t.integer "issue_goal_timeout_seconds", default: 600, null: false
    t.jsonb "kb_chat_fallback_runners", default: [], null: false
    t.string "kb_chat_runner", default: "claude", null: false
    t.jsonb "kb_embedding_fallback_runners", default: [], null: false
    t.string "kb_embedding_runner", default: "openai", null: false
    t.jsonb "log_data"
    t.boolean "marketplace_auto_attach_enabled", default: false, null: false, comment: "Whether this user opts their own agent runs into automatic and team-default marketplace attachments."
    t.integer "max_auto_pick_open_prs", default: 1, null: false
    t.integer "max_comment_length", default: 2000, null: false
    t.integer "max_concurrent_runs", default: 2
    t.integer "max_execution_seconds", comment: "User-level override for project max_execution_seconds; nil defers to project setting"
    t.integer "max_issues_per_page", default: 50, null: false
    t.integer "max_parallel_agents_per_project", default: 3, null: false
    t.integer "max_prompt_comments", default: 20, null: false
    t.integer "max_prs_per_page", default: 50, null: false
    t.integer "max_tokens_per_run", default: 10000000, null: false
    t.float "retry_base_delay", default: 1.0, null: false
    t.integer "retry_max_attempts", default: 3, null: false
    t.float "retry_max_delay", default: 60.0, null: false
    t.integer "review_goal_idle_timeout_seconds", default: 300, null: false
    t.string "run_concurrency_mode", default: "manual", null: false, comment: "Whether agent run admission uses the fixed max_concurrent_runs limit or Docker-capacity auto admission."
    t.jsonb "runner_round_robin_state", default: {}, null: false
    t.string "runner_selection_mode", limit: 20, default: "single", null: false
    t.integer "style_guide_max_raw_bytes", default: 100000, null: false
    t.integer "style_guide_max_raw_prompt_bytes", default: 8000, null: false
    t.integer "style_guide_max_total_bytes", default: 32000, null: false
    t.string "theme_preference", default: "system", null: false
    t.integer "token_validation_stale_minutes", default: 2, null: false
    t.datetime "updated_at", null: false
    t.bigint "user_id", null: false
    t.index ["user_id"], name: "index_user_settings_on_user_id", unique: true
    t.check_constraint "max_issues_per_page >= 5 AND max_issues_per_page <= 200", name: "chk_max_issues_per_page_bounds"
    t.check_constraint "max_prs_per_page >= 5 AND max_prs_per_page <= 200", name: "chk_max_prs_per_page_bounds"
    t.check_constraint "runner_selection_mode::text = ANY (ARRAY['single'::character varying::text, 'round_robin'::character varying::text, 'random'::character varying::text])", name: "chk_runner_selection_mode"
  end

  create_table "users", force: :cascade do |t|
    t.bigint "account_id", null: false
    t.datetime "created_at", null: false
    t.string "email", default: "", null: false
    t.string "encrypted_password", default: "", null: false
    t.jsonb "log_data"
    t.string "name"
    t.datetime "remember_created_at"
    t.datetime "reset_password_sent_at"
    t.string "reset_password_token"
    t.datetime "updated_at", null: false
    t.index ["account_id"], name: "index_users_on_account_id"
    t.index ["email"], name: "index_users_on_email", unique: true
    t.index ["reset_password_token"], name: "index_users_on_reset_password_token", unique: true
  end

  create_table "workflow_states", force: :cascade do |t|
    t.datetime "completed_at"
    t.datetime "created_at", null: false
    t.text "error_message"
    t.jsonb "input_data"
    t.bigint "project_id"
    t.text "restart_reason"
    t.jsonb "result_data"
    t.datetime "started_at"
    t.string "status", limit: 50, default: "running", null: false
    t.string "temporal_run_id"
    t.string "temporal_workflow_id", null: false
    t.datetime "updated_at", null: false
    t.string "workflow_type", limit: 100, null: false
    t.index ["project_id"], name: "index_workflow_states_on_project_id"
    t.index ["status"], name: "index_workflow_states_on_status"
    t.index ["temporal_workflow_id"], name: "index_workflow_states_on_temporal_workflow_id", unique: true
  end

  create_table "worktrees", force: :cascade do |t|
    t.bigint "agent_run_id"
    t.string "base_commit", limit: 40
    t.string "branch_name", null: false
    t.datetime "cleaned_at"
    t.datetime "created_at", null: false
    t.string "path", null: false
    t.bigint "project_id", null: false
    t.boolean "pushed", default: false, null: false
    t.string "status", limit: 50, default: "active", null: false
    t.datetime "updated_at", null: false
    t.index ["agent_run_id"], name: "index_worktrees_on_agent_run_id"
    t.index ["project_id", "branch_name"], name: "index_worktrees_on_project_id_and_branch_name", unique: true
    t.index ["project_id"], name: "index_worktrees_on_project_id"
    t.index ["status"], name: "index_worktrees_on_status"
  end

  add_foreign_key "ab_test_assignments", "ab_test_variants", on_delete: :cascade
  add_foreign_key "ab_test_assignments", "ab_tests", on_delete: :cascade
  add_foreign_key "ab_test_assignments", "agent_runs", on_delete: :cascade
  add_foreign_key "ab_test_variants", "ab_tests", on_delete: :cascade
  add_foreign_key "ab_test_variants", "prompt_versions", on_delete: :restrict
  add_foreign_key "ab_tests", "ab_test_variants", column: "winner_variant_id", on_delete: :nullify
  add_foreign_key "ab_tests", "prompt_versions", column: "control_version_id", on_delete: :restrict
  add_foreign_key "ab_tests", "prompts", on_delete: :cascade
  add_foreign_key "account_activity_events", "accounts"
  add_foreign_key "account_activity_events", "users", column: "actor_id"
  add_foreign_key "account_memberships", "accounts"
  add_foreign_key "account_memberships", "users"
  add_foreign_key "agent_coordination_signals", "agent_runs", column: "source_agent_run_id"
  add_foreign_key "agent_coordination_signals", "agent_runs", column: "target_agent_run_id"
  add_foreign_key "agent_run_anomalies", "agent_runs"
  add_foreign_key "agent_run_anomalies", "projects"
  add_foreign_key "agent_run_logs", "agent_runs", on_delete: :cascade
  add_foreign_key "agent_run_marketplace_entries", "agent_runs"
  add_foreign_key "agent_run_marketplace_entries", "marketplace_entries"
  add_foreign_key "agent_run_marketplace_entries", "marketplace_entry_versions"
  add_foreign_key "agent_run_phases", "agent_runs", on_delete: :cascade
  add_foreign_key "agent_run_resource_profiles", "accounts", on_delete: :cascade
  add_foreign_key "agent_run_resource_profiles", "projects", on_delete: :cascade
  add_foreign_key "agent_runs", "configuration_bundles", on_delete: :nullify
  add_foreign_key "agent_runs", "issues", on_delete: :nullify
  add_foreign_key "agent_runs", "projects", on_delete: :cascade
  add_foreign_key "agent_runs", "prompt_versions", on_delete: :nullify
  add_foreign_key "agent_runs", "runners", name: "fk_agent_runs_runner_id", on_delete: :nullify
  add_foreign_key "agent_runs", "users", column: "initiating_user_id", on_delete: :nullify
  add_foreign_key "billing_invoices", "accounts"
  add_foreign_key "billing_invoices", "billing_periods"
  add_foreign_key "billing_line_items", "billing_invoices"
  add_foreign_key "billing_periods", "accounts"
  add_foreign_key "billing_periods", "billing_plans"
  add_foreign_key "billing_plans", "accounts"
  add_foreign_key "bundle_outcomes", "agent_runs", on_delete: :cascade
  add_foreign_key "bundle_outcomes", "configuration_bundles", on_delete: :cascade
  add_foreign_key "change_intents", "change_intents", column: "superseded_by_id", on_delete: :nullify
  add_foreign_key "change_intents", "chat_sessions", on_delete: :nullify
  add_foreign_key "change_intents", "issues", on_delete: :nullify
  add_foreign_key "change_intents", "projects", on_delete: :cascade
  add_foreign_key "chat_messages", "chat_sessions"
  add_foreign_key "chat_session_projects", "chat_sessions"
  add_foreign_key "chat_session_projects", "projects"
  add_foreign_key "chat_sessions", "accounts"
  add_foreign_key "chat_sessions", "projects"
  add_foreign_key "chat_sessions", "runners", name: "fk_chat_sessions_runner_id"
  add_foreign_key "chat_sessions", "users", column: "created_by_id"
  add_foreign_key "claude_login_sessions", "accounts"
  add_foreign_key "claude_login_sessions", "integration_credentials"
  add_foreign_key "claude_login_sessions", "runner_credentials"
  add_foreign_key "claude_login_sessions", "users", column: "created_by_id"
  add_foreign_key "codex_login_sessions", "accounts"
  add_foreign_key "codex_login_sessions", "runner_credentials"
  add_foreign_key "codex_login_sessions", "users", column: "created_by_id"
  add_foreign_key "collector_runs", "project_versions"
  add_foreign_key "configuration_bundles", "accounts", on_delete: :cascade
  add_foreign_key "configuration_bundles", "llm_models", on_delete: :nullify
  add_foreign_key "configuration_bundles", "projects", on_delete: :cascade
  add_foreign_key "configuration_bundles", "prompt_versions", on_delete: :nullify
  add_foreign_key "configuration_experiment_assignments", "agent_runs", on_delete: :cascade
  add_foreign_key "configuration_experiment_assignments", "configuration_experiment_variants", on_delete: :cascade
  add_foreign_key "configuration_experiment_assignments", "configuration_experiments", on_delete: :cascade
  add_foreign_key "configuration_experiment_variants", "configuration_experiments", on_delete: :cascade
  add_foreign_key "configuration_experiments", "accounts", on_delete: :cascade
  add_foreign_key "configuration_experiments", "configuration_experiment_variants", column: "winner_variant_id", on_delete: :nullify
  add_foreign_key "container_metrics", "agent_runs", on_delete: :cascade
  add_foreign_key "container_pool_entries", "agent_runs", on_delete: :nullify
  add_foreign_key "container_pool_entries", "projects", on_delete: :cascade
  add_foreign_key "context_intake_questions", "projects"
  add_foreign_key "context_intake_responses", "context_intake_responses", column: "parent_response_id"
  add_foreign_key "context_intake_responses", "context_intake_sessions"
  add_foreign_key "context_intake_sessions", "projects"
  add_foreign_key "context_intake_sessions", "users", column: "started_by_id"
  add_foreign_key "coordination_experiment_assignments", "coordination_experiment_variants", on_delete: :cascade
  add_foreign_key "coordination_experiment_assignments", "coordination_experiments", on_delete: :cascade
  add_foreign_key "coordination_experiment_assignments", "issues", on_delete: :nullify
  add_foreign_key "coordination_experiment_assignments", "projects", on_delete: :cascade
  add_foreign_key "coordination_experiment_variants", "coordination_experiments", on_delete: :cascade
  add_foreign_key "coordination_experiments", "accounts", on_delete: :cascade
  add_foreign_key "coordination_experiments", "coordination_experiment_variants", column: "winner_variant_id", on_delete: :nullify
  add_foreign_key "coordination_policies", "accounts", on_delete: :cascade
  add_foreign_key "coordination_policies", "coordination_policy_versions", column: "current_version_id", on_delete: :nullify
  add_foreign_key "coordination_policies", "projects", on_delete: :cascade
  add_foreign_key "coordination_policy_versions", "coordination_policies", on_delete: :cascade
  add_foreign_key "cost_budgets", "projects", on_delete: :cascade
  add_foreign_key "decision_record_links", "decision_records", on_delete: :cascade
  add_foreign_key "decision_records", "agent_runs", on_delete: :nullify
  add_foreign_key "decision_records", "decision_records", column: "superseded_by_id", on_delete: :nullify
  add_foreign_key "decision_records", "issues", on_delete: :nullify
  add_foreign_key "decision_records", "projects", on_delete: :cascade
  add_foreign_key "decomposition_decisions", "issues", on_delete: :cascade
  add_foreign_key "decomposition_decisions", "projects", on_delete: :cascade
  add_foreign_key "dispatch_circuit_breakers", "accounts"
  add_foreign_key "dispatch_circuit_breakers", "agent_runs", column: "last_probe_run_id", on_delete: :nullify, validate: false
  add_foreign_key "docker_hosts", "accounts"
  add_foreign_key "exception_incidents", "accounts"
  add_foreign_key "exception_incidents", "projects"
  add_foreign_key "external_connector_events", "accounts"
  add_foreign_key "external_connector_events", "projects"
  add_foreign_key "failure_classifications", "agent_runs", on_delete: :cascade
  add_foreign_key "failure_classifications", "projects", on_delete: :cascade
  add_foreign_key "github_installations", "accounts"
  add_foreign_key "github_tokens", "accounts"
  add_foreign_key "github_tokens", "users", column: "created_by_id"
  add_foreign_key "integration_credentials", "accounts"
  add_foreign_key "integration_credentials", "users", column: "created_by_id"
  add_foreign_key "issue_dependencies", "issues", column: "depends_on_issue_id", on_delete: :cascade
  add_foreign_key "issue_dependencies", "issues", on_delete: :cascade
  add_foreign_key "issue_merge_subscriptions", "issues"
  add_foreign_key "issue_merge_subscriptions", "users"
  add_foreign_key "issues", "issues", column: "parent_issue_id"
  add_foreign_key "issues", "projects"
  add_foreign_key "knowledge_artifacts", "collector_runs", on_delete: :cascade
  add_foreign_key "knowledge_artifacts", "projects"
  add_foreign_key "knowledge_audit_events", "projects", on_delete: :cascade
  add_foreign_key "knowledge_chunks", "knowledge_artifacts", on_delete: :cascade
  add_foreign_key "knowledge_chunks", "projects"
  add_foreign_key "knowledge_links", "knowledge_chunks", column: "source_chunk_id", on_delete: :cascade
  add_foreign_key "knowledge_links", "knowledge_chunks", column: "target_chunk_id", on_delete: :cascade
  add_foreign_key "knowledge_recommendations", "projects", on_delete: :cascade
  add_foreign_key "knowledge_runs", "projects", on_delete: :cascade
  add_foreign_key "knowledge_usage_stats", "agent_runs", on_delete: :cascade
  add_foreign_key "knowledge_usage_stats", "projects", on_delete: :cascade
  add_foreign_key "linear_tokens", "accounts"
  add_foreign_key "linear_tokens", "users", column: "created_by_id"
  add_foreign_key "llm_models", "llm_models", column: "free_variant_of_id"
  add_foreign_key "llm_output_metrics", "accounts", on_delete: :cascade
  add_foreign_key "llm_output_metrics", "projects", on_delete: :cascade
  add_foreign_key "llm_output_metrics", "prompt_versions", on_delete: :nullify
  add_foreign_key "marketplace_entries", "accounts"
  add_foreign_key "marketplace_entries", "marketplace_entry_versions", column: "current_version_id", on_delete: :nullify
  add_foreign_key "marketplace_entry_rules", "marketplace_entries"
  add_foreign_key "marketplace_entry_versions", "marketplace_entries"
  add_foreign_key "mcp_server_definitions", "accounts"
  add_foreign_key "model_selections", "agent_runs", on_delete: :cascade
  add_foreign_key "model_selections", "llm_models"
  add_foreign_key "notification_rule_states", "accounts"
  add_foreign_key "notifications", "accounts"
  add_foreign_key "notifications", "users", on_delete: :nullify
  add_foreign_key "onboarding_steps", "accounts"
  add_foreign_key "orchestration_decisions", "agent_runs", on_delete: :nullify
  add_foreign_key "orchestration_decisions", "projects", on_delete: :cascade
  add_foreign_key "orchestration_decisions", "strategy_versions", on_delete: :nullify
  add_foreign_key "orchestration_strategies", "accounts"
  add_foreign_key "pending_install_claims", "accounts"
  add_foreign_key "pr_templates", "accounts", on_delete: :cascade
  add_foreign_key "pr_templates", "projects", on_delete: :cascade
  add_foreign_key "pr_templates", "users", on_delete: :cascade
  add_foreign_key "pre_commit_requirements", "accounts", on_delete: :cascade
  add_foreign_key "pre_commit_requirements", "projects", on_delete: :cascade
  add_foreign_key "pre_commit_requirements", "users", on_delete: :cascade
  add_foreign_key "preview_provision_states", "agent_runs", on_delete: :cascade
  add_foreign_key "preview_sessions", "accounts", on_delete: :cascade
  add_foreign_key "preview_sessions", "agent_runs"
  add_foreign_key "preview_sessions", "projects"
  add_foreign_key "preview_sessions", "users", column: "created_by_id", on_delete: :nullify
  add_foreign_key "project_baselines", "projects"
  add_foreign_key "project_convention_detections", "project_versions"
  add_foreign_key "project_convention_detections", "projects"
  add_foreign_key "project_convention_overrides", "projects"
  add_foreign_key "project_convention_recommendations", "projects"
  add_foreign_key "project_convention_recommendations", "users", column: "applied_by_id"
  add_foreign_key "project_convention_recommendations", "users", column: "dismissed_by_id"
  add_foreign_key "project_mcp_servers", "mcp_server_definitions"
  add_foreign_key "project_mcp_servers", "projects"
  add_foreign_key "project_memberships", "projects"
  add_foreign_key "project_memberships", "users"
  add_foreign_key "project_service_containers", "projects", on_delete: :cascade
  add_foreign_key "project_service_containers", "service_containers", on_delete: :cascade
  add_foreign_key "project_versions", "projects"
  add_foreign_key "projects", "accounts"
  add_foreign_key "projects", "github_installations", validate: false
  add_foreign_key "projects", "github_tokens"
  add_foreign_key "projects", "github_tokens", column: "git_push_fallback_token_id", validate: false
  add_foreign_key "projects", "users", column: "created_by_id"
  add_foreign_key "prompt_versions", "prompt_versions", column: "parent_version_id", on_delete: :nullify
  add_foreign_key "prompt_versions", "prompts", on_delete: :cascade
  add_foreign_key "prompt_versions", "users", column: "created_by_user_id", on_delete: :nullify
  add_foreign_key "prompt_versions", "users", column: "reviewed_by_user_id", on_delete: :nullify
  add_foreign_key "prompts", "accounts", on_delete: :cascade
  add_foreign_key "prompts", "projects", on_delete: :cascade
  add_foreign_key "prompts", "prompt_versions", column: "current_version_id", on_delete: :nullify
  add_foreign_key "provider_api_keys", "users", on_delete: :cascade
  add_foreign_key "quality_gate_events", "projects"
  add_foreign_key "quality_gate_events", "quality_gate_thresholds"
  add_foreign_key "quality_gate_events", "quality_metrics"
  add_foreign_key "quality_gate_thresholds", "projects"
  add_foreign_key "quality_metrics", "agent_runs", on_delete: :cascade
  add_foreign_key "quality_metrics", "prompt_versions", on_delete: :nullify
  add_foreign_key "quality_pause_events", "agent_runs"
  add_foreign_key "quality_pause_events", "projects"
  add_foreign_key "quality_recovery_actions", "agent_runs", on_delete: :nullify
  add_foreign_key "quality_recovery_actions", "projects", on_delete: :cascade
  add_foreign_key "quality_recovery_actions", "prompt_versions", on_delete: :nullify
  add_foreign_key "quality_thresholds", "accounts"
  add_foreign_key "quality_thresholds", "projects"
  add_foreign_key "remediation_decisions", "accounts"
  add_foreign_key "remediation_decisions", "users", column: "applied_by_id"
  add_foreign_key "roi_benchmarks", "projects", on_delete: :cascade
  add_foreign_key "runner_auth_attempts", "accounts"
  add_foreign_key "runner_auth_attempts", "agent_runs", on_delete: :nullify
  add_foreign_key "runner_auth_attempts", "projects", on_delete: :cascade
  add_foreign_key "runner_auth_attempts", "runner_credentials", on_delete: :nullify
  add_foreign_key "runner_credentials", "accounts"
  add_foreign_key "runner_credentials", "users", column: "created_by_id", on_delete: :nullify
  add_foreign_key "runner_states", "users", on_delete: :cascade
  add_foreign_key "runners", "integration_credentials", on_delete: :restrict
  add_foreign_key "runners", "provider_api_keys", on_delete: :restrict
  add_foreign_key "runners", "users", on_delete: :cascade
  add_foreign_key "scaling_experiment_assignments", "issues", on_delete: :nullify
  add_foreign_key "scaling_experiment_assignments", "projects", on_delete: :cascade
  add_foreign_key "scaling_experiment_assignments", "scaling_experiments", on_delete: :cascade
  add_foreign_key "scaling_experiment_assignments", "scaling_observations", on_delete: :nullify
  add_foreign_key "scaling_experiments", "projects", on_delete: :cascade
  add_foreign_key "scaling_observations", "issues", on_delete: :nullify
  add_foreign_key "scaling_observations", "projects", on_delete: :cascade
  add_foreign_key "service_container_metrics", "service_containers", on_delete: :cascade
  add_foreign_key "service_containers", "accounts"
  add_foreign_key "strategies", "accounts", on_delete: :cascade
  add_foreign_key "strategies", "projects", on_delete: :cascade
  add_foreign_key "strategies", "strategy_versions", column: "current_version_id", on_delete: :nullify
  add_foreign_key "strategy_experiment_assignments", "agent_runs", on_delete: :cascade
  add_foreign_key "strategy_experiment_assignments", "strategy_experiment_variants", on_delete: :cascade
  add_foreign_key "strategy_experiment_assignments", "strategy_experiments", on_delete: :cascade
  add_foreign_key "strategy_experiment_variants", "strategy_experiments", on_delete: :cascade
  add_foreign_key "strategy_experiments", "accounts", on_delete: :cascade
  add_foreign_key "strategy_experiments", "strategy_experiment_variants", column: "winner_variant_id", on_delete: :nullify
  add_foreign_key "strategy_versions", "strategies", on_delete: :cascade
  add_foreign_key "strategy_versions", "strategy_versions", column: "parent_version_id", on_delete: :nullify
  add_foreign_key "strategy_versions", "users", column: "created_by_user_id", on_delete: :nullify
  add_foreign_key "strategy_versions", "users", column: "promoted_by_user_id", on_delete: :nullify
  add_foreign_key "style_guide_ab_test_assignments", "agent_runs", on_delete: :cascade
  add_foreign_key "style_guide_ab_test_assignments", "style_guide_ab_test_variants", on_delete: :cascade
  add_foreign_key "style_guide_ab_test_assignments", "style_guide_ab_tests", on_delete: :cascade
  add_foreign_key "style_guide_ab_test_variants", "style_guide_ab_tests", on_delete: :cascade
  add_foreign_key "style_guide_ab_test_variants", "style_guide_versions", on_delete: :restrict
  add_foreign_key "style_guide_ab_tests", "accounts", on_delete: :cascade
  add_foreign_key "style_guide_ab_tests", "style_guide_versions", column: "control_version_id", on_delete: :restrict
  add_foreign_key "style_guide_ab_tests", "style_guides", on_delete: :cascade
  add_foreign_key "style_guide_run_exposures", "agent_runs", on_delete: :cascade
  add_foreign_key "style_guide_run_exposures", "style_guide_ab_test_assignments", on_delete: :nullify
  add_foreign_key "style_guide_run_exposures", "style_guide_versions", on_delete: :restrict
  add_foreign_key "style_guide_run_exposures", "style_guides", on_delete: :nullify
  add_foreign_key "style_guide_versions", "style_guide_versions", column: "parent_version_id", on_delete: :nullify
  add_foreign_key "style_guide_versions", "style_guides", on_delete: :cascade
  add_foreign_key "style_guide_versions", "users", column: "created_by_user_id", on_delete: :nullify
  add_foreign_key "style_guide_versions", "users", column: "reviewed_by_user_id", on_delete: :nullify
  add_foreign_key "style_guides", "accounts", on_delete: :cascade
  add_foreign_key "style_guides", "projects", on_delete: :cascade
  add_foreign_key "style_guides", "style_guide_versions", column: "current_version_id", on_delete: :nullify
  add_foreign_key "tenant_settings", "accounts"
  add_foreign_key "token_usages", "agent_runs", on_delete: :cascade
  add_foreign_key "token_usages", "chat_sessions", on_delete: :cascade
  add_foreign_key "token_usages", "knowledge_runs", on_delete: :cascade
  add_foreign_key "tracker_configurations", "integration_credentials"
  add_foreign_key "tracker_configurations", "users", column: "created_by_id"
  add_foreign_key "user_settings", "users"
  add_foreign_key "users", "accounts"
  add_foreign_key "workflow_states", "projects"
  add_foreign_key "worktrees", "agent_runs", on_delete: :nullify
  add_foreign_key "worktrees", "projects", on_delete: :cascade

  create_function :logidze_capture_exception, sql_definition: <<-'SQL'
      CREATE OR REPLACE FUNCTION public.logidze_capture_exception(error_data jsonb)
       RETURNS boolean
       LANGUAGE plpgsql
      AS $function$
        -- version: 1
      BEGIN
        -- Feel free to change this function to change Logidze behavior on exception.
        --
        -- Return `false` to raise exception or `true` to commit record changes.
        --
        -- `error_data` contains:
        --   - returned_sqlstate
        --   - message_text
        --   - pg_exception_detail
        --   - pg_exception_hint
        --   - pg_exception_context
        --   - schema_name
        --   - table_name
        -- Learn more about available keys:
        -- https://www.postgresql.org/docs/9.6/plpgsql-control-structures.html#PLPGSQL-EXCEPTION-DIAGNOSTICS-VALUES
        --

        return false;
      END;
      $function$
  SQL

  create_function :logidze_compact_history, sql_definition: <<-'SQL'
      CREATE OR REPLACE FUNCTION public.logidze_compact_history(log_data jsonb, cutoff integer DEFAULT 1)
       RETURNS jsonb
       LANGUAGE plpgsql
      AS $function$
        -- version: 1
        DECLARE
          merged jsonb;
        BEGIN
          LOOP
            merged := jsonb_build_object(
              'ts',
              log_data#>'{h,1,ts}',
              'v',
              log_data#>'{h,1,v}',
              'c',
              (log_data#>'{h,0,c}') || (log_data#>'{h,1,c}')
            );

            IF (log_data#>'{h,1}' ? 'm') THEN
              merged := jsonb_set(merged, ARRAY['m'], log_data#>'{h,1,m}');
            END IF;

            log_data := jsonb_set(
              log_data,
              '{h}',
              jsonb_set(
                log_data->'h',
                '{1}',
                merged
              ) - 0
            );

            cutoff := cutoff - 1;

            EXIT WHEN cutoff <= 0;
          END LOOP;

          return log_data;
        END;
      $function$
  SQL

  create_function :logidze_filter_keys, sql_definition: <<-'SQL'
      CREATE OR REPLACE FUNCTION public.logidze_filter_keys(obj jsonb, keys text[], include_columns boolean DEFAULT false)
       RETURNS jsonb
       LANGUAGE plpgsql
      AS $function$
        -- version: 1
        DECLARE
          res jsonb;
          key text;
        BEGIN
          res := '{}';

          IF include_columns THEN
            FOREACH key IN ARRAY keys
            LOOP
              IF obj ? key THEN
                res = jsonb_insert(res, ARRAY[key], obj->key);
              END IF;
            END LOOP;
          ELSE
            res = obj;
            FOREACH key IN ARRAY keys
            LOOP
              res = res - key;
            END LOOP;
          END IF;

          RETURN res;
        END;
      $function$
  SQL

  create_function :logidze_logger, sql_definition: <<-'SQL'
      CREATE OR REPLACE FUNCTION public.logidze_logger()
       RETURNS trigger
       LANGUAGE plpgsql
      AS $function$
        -- version: 5
        DECLARE
          changes jsonb;
          version jsonb;
          full_snapshot boolean;
          log_data jsonb;
          new_v integer;
          size integer;
          history_limit integer;
          debounce_time integer;
          current_version integer;
          k text;
          iterator integer;
          item record;
          columns text[];
          include_columns boolean;
          detached_log_data jsonb;
          -- We use `detached_loggable_type` for:
          -- 1. Checking if current implementation is `--detached` (`log_data` is stored in a separated table)
          -- 2. If implementation is `--detached` then we use detached_loggable_type to determine
          --    to which table current `log_data` record belongs
          detached_loggable_type text;
          log_data_table_name text;
          log_data_is_empty boolean;
          log_data_ts_key_data text;
          ts timestamp with time zone;
          ts_column text;
          err_sqlstate text;
          err_message text;
          err_detail text;
          err_hint text;
          err_context text;
          err_table_name text;
          err_schema_name text;
          err_jsonb jsonb;
          err_captured boolean;
        BEGIN
          ts_column := NULLIF(TG_ARGV[1], 'null');
          columns := NULLIF(TG_ARGV[2], 'null');
          include_columns := NULLIF(TG_ARGV[3], 'null');
          detached_loggable_type := NULLIF(TG_ARGV[5], 'null');
          log_data_table_name := NULLIF(TG_ARGV[6], 'null');

          -- getting previous log_data if it exists for detached `log_data` storage variant
          IF detached_loggable_type IS NOT NULL
          THEN
            EXECUTE format(
              'SELECT ldtn.log_data ' ||
              'FROM %I ldtn ' ||
              'WHERE ldtn.loggable_type = $1 ' ||
                'AND ldtn.loggable_id = $2 '  ||
              'LIMIT 1',
              log_data_table_name
            ) USING detached_loggable_type, NEW.id INTO detached_log_data;
          END IF;

          IF detached_loggable_type IS NULL
          THEN
              log_data_is_empty = NEW.log_data is NULL OR NEW.log_data = '{}'::jsonb;
          ELSE
              log_data_is_empty = detached_log_data IS NULL OR detached_log_data = '{}'::jsonb;
          END IF;

          IF log_data_is_empty
          THEN
            IF columns IS NOT NULL THEN
              log_data = logidze_snapshot(to_jsonb(NEW.*), ts_column, columns, include_columns);
            ELSE
              log_data = logidze_snapshot(to_jsonb(NEW.*), ts_column);
            END IF;

            IF log_data#>>'{h, -1, c}' != '{}' THEN
              IF detached_loggable_type IS NULL
              THEN
                NEW.log_data := log_data;
              ELSE
                EXECUTE format(
                  'INSERT INTO %I(log_data, loggable_type, loggable_id) ' ||
                  'VALUES ($1, $2, $3);',
                  log_data_table_name
                ) USING log_data, detached_loggable_type, NEW.id;
              END IF;
            END IF;

          ELSE

            IF TG_OP = 'UPDATE' AND (to_jsonb(NEW.*) = to_jsonb(OLD.*)) THEN
              RETURN NEW; -- pass
            END IF;

            history_limit := NULLIF(TG_ARGV[0], 'null');
            debounce_time := NULLIF(TG_ARGV[4], 'null');

            IF detached_loggable_type IS NULL
            THEN
                log_data := NEW.log_data;
            ELSE
                log_data := detached_log_data;
            END IF;

            current_version := (log_data->>'v')::int;

            IF ts_column IS NULL THEN
              ts := statement_timestamp();
            ELSEIF TG_OP = 'UPDATE' THEN
              ts := (to_jsonb(NEW.*) ->> ts_column)::timestamp with time zone;
              IF ts IS NULL OR ts = (to_jsonb(OLD.*) ->> ts_column)::timestamp with time zone THEN
                ts := statement_timestamp();
              END IF;
            ELSEIF TG_OP = 'INSERT' THEN
              ts := (to_jsonb(NEW.*) ->> ts_column)::timestamp with time zone;

              IF detached_loggable_type IS NULL
              THEN
                log_data_ts_key_data = NEW.log_data #>> '{h,-1,ts}';
              ELSE
                log_data_ts_key_data = detached_log_data #>> '{h,-1,ts}';
              END IF;

              IF ts IS NULL OR (extract(epoch from ts) * 1000)::bigint = log_data_ts_key_data::bigint THEN
                  ts := statement_timestamp();
              END IF;
            END IF;

            full_snapshot := (coalesce(current_setting('logidze.full_snapshot', true), '') = 'on') OR (TG_OP = 'INSERT');

            IF current_version < (log_data#>>'{h,-1,v}')::int THEN
              iterator := 0;
              FOR item in SELECT * FROM jsonb_array_elements(log_data->'h')
              LOOP
                IF (item.value->>'v')::int > current_version THEN
                  log_data := jsonb_set(
                    log_data,
                    '{h}',
                    (log_data->'h') - iterator
                  );
                END IF;
                iterator := iterator + 1;
              END LOOP;
            END IF;

            changes := '{}';

            IF full_snapshot THEN
              BEGIN
                changes = hstore_to_jsonb_loose(hstore(NEW.*));
              EXCEPTION
                WHEN NUMERIC_VALUE_OUT_OF_RANGE THEN
                  changes = row_to_json(NEW.*)::jsonb;
                  FOR k IN (SELECT key FROM jsonb_each(changes))
                  LOOP
                    IF jsonb_typeof(changes->k) = 'object' THEN
                      changes = jsonb_set(changes, ARRAY[k], to_jsonb(changes->>k));
                    END IF;
                  END LOOP;
              END;
            ELSE
              BEGIN
                changes = hstore_to_jsonb_loose(
                      hstore(NEW.*) - hstore(OLD.*)
                  );
              EXCEPTION
                WHEN NUMERIC_VALUE_OUT_OF_RANGE THEN
                  changes = (SELECT
                    COALESCE(json_object_agg(key, value), '{}')::jsonb
                    FROM
                    jsonb_each(row_to_json(NEW.*)::jsonb)
                    WHERE NOT jsonb_build_object(key, value) <@ row_to_json(OLD.*)::jsonb);
                  FOR k IN (SELECT key FROM jsonb_each(changes))
                  LOOP
                    IF jsonb_typeof(changes->k) = 'object' THEN
                      changes = jsonb_set(changes, ARRAY[k], to_jsonb(changes->>k));
                    END IF;
                  END LOOP;
              END;
            END IF;

            -- We store `log_data` in a separate table for the `detached` mode
            -- So we remove `log_data` only when we store historic data in the record's origin table
            IF detached_loggable_type IS NULL
            THEN
                changes = changes - 'log_data';
            END IF;

            IF columns IS NOT NULL THEN
              changes = logidze_filter_keys(changes, columns, include_columns);
            END IF;

            IF changes = '{}' THEN
              RETURN NEW; -- pass
            END IF;

            new_v := (log_data#>>'{h,-1,v}')::int + 1;

            size := jsonb_array_length(log_data->'h');
            version := logidze_version(new_v, changes, ts);

            IF (
              debounce_time IS NOT NULL AND
              (version->>'ts')::bigint - (log_data#>'{h,-1,ts}')::text::bigint <= debounce_time
            ) THEN
              -- merge new version with the previous one
              new_v := (log_data#>>'{h,-1,v}')::int;
              version := logidze_version(new_v, (log_data#>'{h,-1,c}')::jsonb || changes, ts);
              -- remove the previous version from log
              log_data := jsonb_set(
                log_data,
                '{h}',
                (log_data->'h') - (size - 1)
              );
            END IF;

            log_data := jsonb_set(
              log_data,
              ARRAY['h', size::text],
              version,
              true
            );

            log_data := jsonb_set(
              log_data,
              '{v}',
              to_jsonb(new_v)
            );

            IF history_limit IS NOT NULL AND history_limit <= size THEN
              log_data := logidze_compact_history(log_data, size - history_limit + 1);
            END IF;

            IF detached_loggable_type IS NULL
            THEN
              NEW.log_data := log_data;
            ELSE
              detached_log_data = log_data;
              EXECUTE format(
                'UPDATE %I ' ||
                'SET log_data = $1 ' ||
                'WHERE %I.loggable_type = $2 ' ||
                'AND %I.loggable_id = $3',
                log_data_table_name,
                log_data_table_name,
                log_data_table_name
              ) USING detached_log_data, detached_loggable_type, NEW.id;
            END IF;
          END IF;

          RETURN NEW; -- result
        EXCEPTION
          WHEN OTHERS THEN
            GET STACKED DIAGNOSTICS err_sqlstate = RETURNED_SQLSTATE,
                                    err_message = MESSAGE_TEXT,
                                    err_detail = PG_EXCEPTION_DETAIL,
                                    err_hint = PG_EXCEPTION_HINT,
                                    err_context = PG_EXCEPTION_CONTEXT,
                                    err_schema_name = SCHEMA_NAME,
                                    err_table_name = TABLE_NAME;
            err_jsonb := jsonb_build_object(
              'returned_sqlstate', err_sqlstate,
              'message_text', err_message,
              'pg_exception_detail', err_detail,
              'pg_exception_hint', err_hint,
              'pg_exception_context', err_context,
              'schema_name', err_schema_name,
              'table_name', err_table_name
            );
            err_captured = logidze_capture_exception(err_jsonb);
            IF err_captured THEN
              return NEW;
            ELSE
              RAISE;
            END IF;
        END;
      $function$
  SQL

  create_function :logidze_logger_after, sql_definition: <<-'SQL'
      CREATE OR REPLACE FUNCTION public.logidze_logger_after()
       RETURNS trigger
       LANGUAGE plpgsql
      AS $function$
        -- version: 5


        DECLARE
          changes jsonb;
          version jsonb;
          full_snapshot boolean;
          log_data jsonb;
          new_v integer;
          size integer;
          history_limit integer;
          debounce_time integer;
          current_version integer;
          k text;
          iterator integer;
          item record;
          columns text[];
          include_columns boolean;
          detached_log_data jsonb;
          -- We use `detached_loggable_type` for:
          -- 1. Checking if current implementation is `--detached` (`log_data` is stored in a separated table)
          -- 2. If implementation is `--detached` then we use detached_loggable_type to determine
          --    to which table current `log_data` record belongs
          detached_loggable_type text;
          log_data_table_name text;
          log_data_is_empty boolean;
          log_data_ts_key_data text;
          ts timestamp with time zone;
          ts_column text;
          err_sqlstate text;
          err_message text;
          err_detail text;
          err_hint text;
          err_context text;
          err_table_name text;
          err_schema_name text;
          err_jsonb jsonb;
          err_captured boolean;
        BEGIN
          ts_column := NULLIF(TG_ARGV[1], 'null');
          columns := NULLIF(TG_ARGV[2], 'null');
          include_columns := NULLIF(TG_ARGV[3], 'null');
          detached_loggable_type := NULLIF(TG_ARGV[5], 'null');
          log_data_table_name := NULLIF(TG_ARGV[6], 'null');

          -- getting previous log_data if it exists for detached `log_data` storage variant
          IF detached_loggable_type IS NOT NULL
          THEN
            EXECUTE format(
              'SELECT ldtn.log_data ' ||
              'FROM %I ldtn ' ||
              'WHERE ldtn.loggable_type = $1 ' ||
                'AND ldtn.loggable_id = $2 '  ||
              'LIMIT 1',
              log_data_table_name
            ) USING detached_loggable_type, NEW.id INTO detached_log_data;
          END IF;

          IF detached_loggable_type IS NULL
          THEN
              log_data_is_empty = NEW.log_data is NULL OR NEW.log_data = '{}'::jsonb;
          ELSE
              log_data_is_empty = detached_log_data IS NULL OR detached_log_data = '{}'::jsonb;
          END IF;

          IF log_data_is_empty
          THEN
            IF columns IS NOT NULL THEN
              log_data = logidze_snapshot(to_jsonb(NEW.*), ts_column, columns, include_columns);
            ELSE
              log_data = logidze_snapshot(to_jsonb(NEW.*), ts_column);
            END IF;

            IF log_data#>>'{h, -1, c}' != '{}' THEN
              IF detached_loggable_type IS NULL
              THEN
                NEW.log_data := log_data;
              ELSE
                EXECUTE format(
                  'INSERT INTO %I(log_data, loggable_type, loggable_id) ' ||
                  'VALUES ($1, $2, $3);',
                  log_data_table_name
                ) USING log_data, detached_loggable_type, NEW.id;
              END IF;
            END IF;

          ELSE

            IF TG_OP = 'UPDATE' AND (to_jsonb(NEW.*) = to_jsonb(OLD.*)) THEN
              RETURN NULL;
            END IF;

            history_limit := NULLIF(TG_ARGV[0], 'null');
            debounce_time := NULLIF(TG_ARGV[4], 'null');

            IF detached_loggable_type IS NULL
            THEN
                log_data := NEW.log_data;
            ELSE
                log_data := detached_log_data;
            END IF;

            current_version := (log_data->>'v')::int;

            IF ts_column IS NULL THEN
              ts := statement_timestamp();
            ELSEIF TG_OP = 'UPDATE' THEN
              ts := (to_jsonb(NEW.*) ->> ts_column)::timestamp with time zone;
              IF ts IS NULL OR ts = (to_jsonb(OLD.*) ->> ts_column)::timestamp with time zone THEN
                ts := statement_timestamp();
              END IF;
            ELSEIF TG_OP = 'INSERT' THEN
              ts := (to_jsonb(NEW.*) ->> ts_column)::timestamp with time zone;

              IF detached_loggable_type IS NULL
              THEN
                log_data_ts_key_data = NEW.log_data #>> '{h,-1,ts}';
              ELSE
                log_data_ts_key_data = detached_log_data #>> '{h,-1,ts}';
              END IF;

              IF ts IS NULL OR (extract(epoch from ts) * 1000)::bigint = log_data_ts_key_data::bigint THEN
                  ts := statement_timestamp();
              END IF;
            END IF;

            full_snapshot := (coalesce(current_setting('logidze.full_snapshot', true), '') = 'on') OR (TG_OP = 'INSERT');

            IF current_version < (log_data#>>'{h,-1,v}')::int THEN
              iterator := 0;
              FOR item in SELECT * FROM jsonb_array_elements(log_data->'h')
              LOOP
                IF (item.value->>'v')::int > current_version THEN
                  log_data := jsonb_set(
                    log_data,
                    '{h}',
                    (log_data->'h') - iterator
                  );
                END IF;
                iterator := iterator + 1;
              END LOOP;
            END IF;

            changes := '{}';

            IF full_snapshot THEN
              BEGIN
                changes = hstore_to_jsonb_loose(hstore(NEW.*));
              EXCEPTION
                WHEN NUMERIC_VALUE_OUT_OF_RANGE THEN
                  changes = row_to_json(NEW.*)::jsonb;
                  FOR k IN (SELECT key FROM jsonb_each(changes))
                  LOOP
                    IF jsonb_typeof(changes->k) = 'object' THEN
                      changes = jsonb_set(changes, ARRAY[k], to_jsonb(changes->>k));
                    END IF;
                  END LOOP;
              END;
            ELSE
              BEGIN
                changes = hstore_to_jsonb_loose(
                      hstore(NEW.*) - hstore(OLD.*)
                  );
              EXCEPTION
                WHEN NUMERIC_VALUE_OUT_OF_RANGE THEN
                  changes = (SELECT
                    COALESCE(json_object_agg(key, value), '{}')::jsonb
                    FROM
                    jsonb_each(row_to_json(NEW.*)::jsonb)
                    WHERE NOT jsonb_build_object(key, value) <@ row_to_json(OLD.*)::jsonb);
                  FOR k IN (SELECT key FROM jsonb_each(changes))
                  LOOP
                    IF jsonb_typeof(changes->k) = 'object' THEN
                      changes = jsonb_set(changes, ARRAY[k], to_jsonb(changes->>k));
                    END IF;
                  END LOOP;
              END;
            END IF;

            -- We store `log_data` in a separate table for the `detached` mode
            -- So we remove `log_data` only when we store historic data in the record's origin table
            IF detached_loggable_type IS NULL
            THEN
                changes = changes - 'log_data';
            END IF;

            IF columns IS NOT NULL THEN
              changes = logidze_filter_keys(changes, columns, include_columns);
            END IF;

            IF changes = '{}' THEN
              RETURN NULL;
            END IF;

            new_v := (log_data#>>'{h,-1,v}')::int + 1;

            size := jsonb_array_length(log_data->'h');
            version := logidze_version(new_v, changes, ts);

            IF (
              debounce_time IS NOT NULL AND
              (version->>'ts')::bigint - (log_data#>'{h,-1,ts}')::text::bigint <= debounce_time
            ) THEN
              -- merge new version with the previous one
              new_v := (log_data#>>'{h,-1,v}')::int;
              version := logidze_version(new_v, (log_data#>'{h,-1,c}')::jsonb || changes, ts);
              -- remove the previous version from log
              log_data := jsonb_set(
                log_data,
                '{h}',
                (log_data->'h') - (size - 1)
              );
            END IF;

            log_data := jsonb_set(
              log_data,
              ARRAY['h', size::text],
              version,
              true
            );

            log_data := jsonb_set(
              log_data,
              '{v}',
              to_jsonb(new_v)
            );

            IF history_limit IS NOT NULL AND history_limit <= size THEN
              log_data := logidze_compact_history(log_data, size - history_limit + 1);
            END IF;

            IF detached_loggable_type IS NULL
            THEN
              NEW.log_data := log_data;
            ELSE
              detached_log_data = log_data;
              EXECUTE format(
                'UPDATE %I ' ||
                'SET log_data = $1 ' ||
                'WHERE %I.loggable_type = $2 ' ||
                'AND %I.loggable_id = $3',
                log_data_table_name,
                log_data_table_name,
                log_data_table_name
              ) USING detached_log_data, detached_loggable_type, NEW.id;
            END IF;
          END IF;

          IF detached_loggable_type IS NULL
          THEN
            EXECUTE format('UPDATE %I.%I SET "log_data" = $1 WHERE ctid = %L', TG_TABLE_SCHEMA, TG_TABLE_NAME, NEW.CTID) USING NEW.log_data;
          END IF;

          RETURN NULL;

        EXCEPTION
          WHEN OTHERS THEN
            GET STACKED DIAGNOSTICS err_sqlstate = RETURNED_SQLSTATE,
                                    err_message = MESSAGE_TEXT,
                                    err_detail = PG_EXCEPTION_DETAIL,
                                    err_hint = PG_EXCEPTION_HINT,
                                    err_context = PG_EXCEPTION_CONTEXT,
                                    err_schema_name = SCHEMA_NAME,
                                    err_table_name = TABLE_NAME;
            err_jsonb := jsonb_build_object(
              'returned_sqlstate', err_sqlstate,
              'message_text', err_message,
              'pg_exception_detail', err_detail,
              'pg_exception_hint', err_hint,
              'pg_exception_context', err_context,
              'schema_name', err_schema_name,
              'table_name', err_table_name
            );
            err_captured = logidze_capture_exception(err_jsonb);
            IF err_captured THEN
              return NEW;
            ELSE
              RAISE;
            END IF;
        END;
      $function$
  SQL

  create_function :logidze_snapshot, sql_definition: <<-'SQL'
      CREATE OR REPLACE FUNCTION public.logidze_snapshot(item jsonb, ts_column text DEFAULT NULL::text, columns text[] DEFAULT NULL::text[], include_columns boolean DEFAULT false)
       RETURNS jsonb
       LANGUAGE plpgsql
      AS $function$
        -- version: 3
        DECLARE
          ts timestamp with time zone;
          k text;
        BEGIN
          item = item - 'log_data';
          IF ts_column IS NULL THEN
            ts := statement_timestamp();
          ELSE
            ts := coalesce((item->>ts_column)::timestamp with time zone, statement_timestamp());
          END IF;

          IF columns IS NOT NULL THEN
            item := logidze_filter_keys(item, columns, include_columns);
          END IF;

          FOR k IN (SELECT key FROM jsonb_each(item))
          LOOP
            IF jsonb_typeof(item->k) = 'object' THEN
               item := jsonb_set(item, ARRAY[k], to_jsonb(item->>k));
            END IF;
          END LOOP;

          return json_build_object(
            'v', 1,
            'h', jsonb_build_array(
                    logidze_version(1, item, ts)
                  )
            );
        END;
      $function$
  SQL

  create_function :logidze_version, sql_definition: <<-'SQL'
      CREATE OR REPLACE FUNCTION public.logidze_version(v bigint, data jsonb, ts timestamp with time zone)
       RETURNS jsonb
       LANGUAGE plpgsql
      AS $function$
        -- version: 2
        DECLARE
          buf jsonb;
        BEGIN
          data = data - 'log_data';
          buf := jsonb_build_object(
                    'ts',
                    (extract(epoch from ts) * 1000)::bigint,
                    'v',
                    v,
                    'c',
                    data
                    );
          IF coalesce(current_setting('logidze.meta', true), '') <> '' THEN
            buf := jsonb_insert(buf, '{m}', current_setting('logidze.meta')::jsonb);
          END IF;
          RETURN buf;
        END;
      $function$
  SQL

  create_function :paid_current_account_id, sql_definition: <<-'SQL'
      CREATE OR REPLACE FUNCTION public.paid_current_account_id()
       RETURNS bigint
       LANGUAGE sql
       STABLE
      AS $function$
        SELECT NULLIF(current_setting('paid.current_account_id', true), '')::bigint
      $function$
  SQL

  create_function :paid_tenant_bypass, sql_definition: <<-'SQL'
      CREATE OR REPLACE FUNCTION public.paid_tenant_bypass()
       RETURNS boolean
       LANGUAGE sql
       STABLE
      AS $function$
        SELECT current_setting('paid.bypass_tenant_rls', true) = 'true'
      $function$
  SQL

  create_function :validate_orchestration_decision_strategy_version_scope, sql_definition: <<-'SQL'
      CREATE OR REPLACE FUNCTION public.validate_orchestration_decision_strategy_version_scope()
       RETURNS trigger
       LANGUAGE plpgsql
       SECURITY DEFINER
       SET search_path TO 'public', 'pg_temp'
      AS $function$
      BEGIN
        IF NEW.strategy_version_id IS NULL THEN
          RETURN NEW;
        END IF;

        IF EXISTS (
          SELECT 1
          FROM strategy_versions
          INNER JOIN strategies ON strategies.id = strategy_versions.strategy_id
          WHERE strategy_versions.id = NEW.strategy_version_id
            AND (
              strategies.account_id IS NULL
              OR (
                strategies.account_id = paid_current_account_id()
                AND (
                  strategies.project_id IS NULL
                  OR strategies.project_id = NEW.project_id
                )
              )
            )
        ) THEN
          RETURN NEW;
        END IF;

        RAISE EXCEPTION 'strategy_version_id must reference a global or same-tenant strategy version';
      END;
      $function$
  SQL

  create_trigger :logidze_on_account_memberships, sql_definition: <<-SQL
      CREATE TRIGGER logidze_on_account_memberships BEFORE INSERT OR UPDATE ON public.account_memberships FOR EACH ROW WHEN ((COALESCE(current_setting('logidze.disabled'::text, true), ''::text) <> 'on'::text)) EXECUTE FUNCTION logidze_logger('null', 'updated_at')
  SQL

  create_trigger :logidze_on_accounts, sql_definition: <<-SQL
      CREATE TRIGGER logidze_on_accounts BEFORE INSERT OR UPDATE ON public.accounts FOR EACH ROW WHEN ((COALESCE(current_setting('logidze.disabled'::text, true), ''::text) <> 'on'::text)) EXECUTE FUNCTION logidze_logger('null', 'updated_at')
  SQL

  create_trigger :logidze_on_billing_invoices, sql_definition: <<-SQL
      CREATE TRIGGER logidze_on_billing_invoices BEFORE INSERT OR UPDATE ON public.billing_invoices FOR EACH ROW WHEN ((COALESCE(current_setting('logidze.disabled'::text, true), ''::text) <> 'on'::text)) EXECUTE FUNCTION logidze_logger('null', 'updated_at')
  SQL

  create_trigger :logidze_on_billing_plans, sql_definition: <<-SQL
      CREATE TRIGGER logidze_on_billing_plans BEFORE INSERT OR UPDATE ON public.billing_plans FOR EACH ROW WHEN ((COALESCE(current_setting('logidze.disabled'::text, true), ''::text) <> 'on'::text)) EXECUTE FUNCTION logidze_logger('null', 'updated_at')
  SQL

  create_trigger :logidze_on_configuration_bundles, sql_definition: <<-SQL
      CREATE TRIGGER logidze_on_configuration_bundles BEFORE INSERT OR UPDATE ON public.configuration_bundles FOR EACH ROW WHEN ((COALESCE(current_setting('logidze.disabled'::text, true), ''::text) <> 'on'::text)) EXECUTE FUNCTION logidze_logger('null', 'updated_at')
  SQL

  create_trigger :logidze_on_cost_budgets, sql_definition: <<-SQL
      CREATE TRIGGER logidze_on_cost_budgets BEFORE INSERT OR UPDATE ON public.cost_budgets FOR EACH ROW WHEN ((COALESCE(current_setting('logidze.disabled'::text, true), ''::text) <> 'on'::text)) EXECUTE FUNCTION logidze_logger('null', 'updated_at')
  SQL

  create_trigger :logidze_on_docker_hosts, sql_definition: <<-SQL
      CREATE TRIGGER logidze_on_docker_hosts BEFORE INSERT OR UPDATE ON public.docker_hosts FOR EACH ROW WHEN ((COALESCE(current_setting('logidze.disabled'::text, true), ''::text) <> 'on'::text)) EXECUTE FUNCTION logidze_logger('null', 'updated_at')
  SQL

  create_trigger :logidze_on_exception_incidents, sql_definition: <<-SQL
      CREATE TRIGGER logidze_on_exception_incidents BEFORE INSERT OR UPDATE ON public.exception_incidents FOR EACH ROW WHEN ((COALESCE(current_setting('logidze.disabled'::text, true), ''::text) <> 'on'::text)) EXECUTE FUNCTION logidze_logger('null', 'updated_at', '{occurrence_count,last_occurred_at,backtrace,context}')
  SQL

  create_trigger :logidze_on_github_tokens, sql_definition: <<-SQL
      CREATE TRIGGER logidze_on_github_tokens BEFORE INSERT OR UPDATE ON public.github_tokens FOR EACH ROW WHEN ((COALESCE(current_setting('logidze.disabled'::text, true), ''::text) <> 'on'::text)) EXECUTE FUNCTION logidze_logger('null', 'updated_at', '{token,last_used_at,repositories_synced_at,accessible_repositories}')
  SQL

  create_trigger :logidze_on_integration_credentials, sql_definition: <<-SQL
      CREATE TRIGGER logidze_on_integration_credentials BEFORE INSERT OR UPDATE ON public.integration_credentials FOR EACH ROW WHEN ((COALESCE(current_setting('logidze.disabled'::text, true), ''::text) <> 'on'::text)) EXECUTE FUNCTION logidze_logger('null', 'updated_at', '{secret}')
  SQL

  create_trigger :knowledge_chunks_tsvector_update, sql_definition: <<-SQL
      CREATE TRIGGER knowledge_chunks_tsvector_update BEFORE INSERT OR UPDATE OF content ON public.knowledge_chunks FOR EACH ROW EXECUTE FUNCTION tsvector_update_trigger('content_tsvector', 'pg_catalog.english', 'content')
  SQL

  create_trigger :logidze_on_llm_models, sql_definition: <<-SQL
      CREATE TRIGGER logidze_on_llm_models BEFORE INSERT OR UPDATE ON public.llm_models FOR EACH ROW WHEN ((COALESCE(current_setting('logidze.disabled'::text, true), ''::text) <> 'on'::text)) EXECUTE FUNCTION logidze_logger('null', 'updated_at')
  SQL

  create_trigger :logidze_on_mcp_server_definitions, sql_definition: <<-SQL
      CREATE TRIGGER logidze_on_mcp_server_definitions BEFORE INSERT OR UPDATE ON public.mcp_server_definitions FOR EACH ROW WHEN ((COALESCE(current_setting('logidze.disabled'::text, true), ''::text) <> 'on'::text)) EXECUTE FUNCTION logidze_logger('null', 'updated_at', '{env}')
  SQL

  create_trigger :validate_strategy_version_scope, sql_definition: <<-SQL
      CREATE TRIGGER validate_strategy_version_scope BEFORE INSERT OR UPDATE OF project_id, strategy_version_id ON public.orchestration_decisions FOR EACH ROW EXECUTE FUNCTION validate_orchestration_decision_strategy_version_scope()
  SQL

  create_trigger :logidze_on_orchestration_strategies, sql_definition: <<-SQL
      CREATE TRIGGER logidze_on_orchestration_strategies BEFORE INSERT OR UPDATE ON public.orchestration_strategies FOR EACH ROW WHEN ((COALESCE(current_setting('logidze.disabled'::text, true), ''::text) <> 'on'::text)) EXECUTE FUNCTION logidze_logger('null', 'updated_at')
  SQL

  create_trigger :logidze_on_pr_templates, sql_definition: <<-SQL
      CREATE TRIGGER logidze_on_pr_templates BEFORE INSERT OR UPDATE ON public.pr_templates FOR EACH ROW WHEN ((COALESCE(current_setting('logidze.disabled'::text, true), ''::text) <> 'on'::text)) EXECUTE FUNCTION logidze_logger('null', 'updated_at')
  SQL

  create_trigger :logidze_on_pre_commit_requirements, sql_definition: <<-SQL
      CREATE TRIGGER logidze_on_pre_commit_requirements BEFORE INSERT OR UPDATE ON public.pre_commit_requirements FOR EACH ROW WHEN ((COALESCE(current_setting('logidze.disabled'::text, true), ''::text) <> 'on'::text)) EXECUTE FUNCTION logidze_logger('null', 'updated_at')
  SQL

  create_trigger :logidze_on_project_memberships, sql_definition: <<-SQL
      CREATE TRIGGER logidze_on_project_memberships BEFORE INSERT OR UPDATE ON public.project_memberships FOR EACH ROW WHEN ((COALESCE(current_setting('logidze.disabled'::text, true), ''::text) <> 'on'::text)) EXECUTE FUNCTION logidze_logger('null', 'updated_at')
  SQL

  create_trigger :logidze_on_projects, sql_definition: <<-SQL
      CREATE TRIGGER logidze_on_projects BEFORE INSERT OR UPDATE ON public.projects FOR EACH ROW WHEN ((COALESCE(current_setting('logidze.disabled'::text, true), ''::text) <> 'on'::text)) EXECUTE FUNCTION logidze_logger('null', 'updated_at', '{last_polled_at,last_agent_run_at,last_github_activity_at,last_issue_sync_at,total_cost_cents,total_tokens_used}')
  SQL

  create_trigger :logidze_on_prompts, sql_definition: <<-SQL
      CREATE TRIGGER logidze_on_prompts BEFORE INSERT OR UPDATE ON public.prompts FOR EACH ROW WHEN ((COALESCE(current_setting('logidze.disabled'::text, true), ''::text) <> 'on'::text)) EXECUTE FUNCTION logidze_logger('null', 'updated_at')
  SQL

  create_trigger :logidze_on_provider_api_keys, sql_definition: <<-SQL
      CREATE TRIGGER logidze_on_provider_api_keys BEFORE INSERT OR UPDATE ON public.provider_api_keys FOR EACH ROW WHEN ((COALESCE(current_setting('logidze.disabled'::text, true), ''::text) <> 'on'::text)) EXECUTE FUNCTION logidze_logger('null', 'updated_at', '{api_key}')
  SQL

  create_trigger :logidze_on_quality_gate_thresholds, sql_definition: <<-SQL
      CREATE TRIGGER logidze_on_quality_gate_thresholds BEFORE INSERT OR UPDATE ON public.quality_gate_thresholds FOR EACH ROW WHEN ((COALESCE(current_setting('logidze.disabled'::text, true), ''::text) <> 'on'::text)) EXECUTE FUNCTION logidze_logger('null', 'updated_at')
  SQL

  create_trigger :logidze_on_quality_thresholds, sql_definition: <<-SQL
      CREATE TRIGGER logidze_on_quality_thresholds BEFORE INSERT OR UPDATE ON public.quality_thresholds FOR EACH ROW WHEN ((COALESCE(current_setting('logidze.disabled'::text, true), ''::text) <> 'on'::text)) EXECUTE FUNCTION logidze_logger('null', 'updated_at')
  SQL

  create_trigger :logidze_on_runner_credentials, sql_definition: <<-SQL
      CREATE TRIGGER logidze_on_runner_credentials BEFORE INSERT OR UPDATE ON public.runner_credentials FOR EACH ROW WHEN ((COALESCE(current_setting('logidze.disabled'::text, true), ''::text) <> 'on'::text)) EXECUTE FUNCTION logidze_logger('null', 'updated_at', '{token}')
  SQL

  create_trigger :logidze_on_providers, sql_definition: <<-SQL
      CREATE TRIGGER logidze_on_providers BEFORE INSERT OR UPDATE ON public.runners FOR EACH ROW WHEN ((COALESCE(current_setting('logidze.disabled'::text, true), ''::text) <> 'on'::text)) EXECUTE FUNCTION logidze_logger('null', 'updated_at')
  SQL

  create_trigger :logidze_on_service_containers, sql_definition: <<-SQL
      CREATE TRIGGER logidze_on_service_containers BEFORE INSERT OR UPDATE ON public.service_containers FOR EACH ROW WHEN ((COALESCE(current_setting('logidze.disabled'::text, true), ''::text) <> 'on'::text)) EXECUTE FUNCTION logidze_logger('null', 'updated_at', '{env,status,docker_container_id,peak_cpu_percent,peak_memory_bytes,avg_cpu_percent,avg_memory_bytes,container_metrics_count}')
  SQL

  create_trigger :logidze_on_style_guides, sql_definition: <<-SQL
      CREATE TRIGGER logidze_on_style_guides BEFORE INSERT OR UPDATE ON public.style_guides FOR EACH ROW WHEN ((COALESCE(current_setting('logidze.disabled'::text, true), ''::text) <> 'on'::text)) EXECUTE FUNCTION logidze_logger('null', 'updated_at')
  SQL

  create_trigger :logidze_on_tenant_settings, sql_definition: <<-SQL
      CREATE TRIGGER logidze_on_tenant_settings BEFORE INSERT OR UPDATE ON public.tenant_settings FOR EACH ROW WHEN ((COALESCE(current_setting('logidze.disabled'::text, true), ''::text) <> 'on'::text)) EXECUTE FUNCTION logidze_logger('null', 'updated_at')
  SQL

  create_trigger :logidze_on_tracker_configurations, sql_definition: <<-SQL
      CREATE TRIGGER logidze_on_tracker_configurations BEFORE INSERT OR UPDATE ON public.tracker_configurations FOR EACH ROW WHEN ((COALESCE(current_setting('logidze.disabled'::text, true), ''::text) <> 'on'::text)) EXECUTE FUNCTION logidze_logger('null', 'updated_at')
  SQL

  create_trigger :logidze_on_user_settings, sql_definition: <<-SQL
      CREATE TRIGGER logidze_on_user_settings BEFORE INSERT OR UPDATE ON public.user_settings FOR EACH ROW WHEN ((COALESCE(current_setting('logidze.disabled'::text, true), ''::text) <> 'on'::text)) EXECUTE FUNCTION logidze_logger('null', 'updated_at')
  SQL

  create_trigger :logidze_on_users, sql_definition: <<-SQL
      CREATE TRIGGER logidze_on_users BEFORE INSERT OR UPDATE ON public.users FOR EACH ROW WHEN ((COALESCE(current_setting('logidze.disabled'::text, true), ''::text) <> 'on'::text)) EXECUTE FUNCTION logidze_logger('null', 'updated_at', '{encrypted_password,reset_password_token,reset_password_sent_at,remember_created_at}')
  SQL
end
