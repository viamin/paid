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

ActiveRecord::Schema[8.1].define(version: 2026_04_07_071652) do
  # These are extensions that must be enabled in order to support this database
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
    t.integer "min_samples_per_variant", default: 30, null: false
    t.string "name", limit: 255, null: false
    t.bigint "prompt_id", null: false
    t.datetime "started_at"
    t.string "status", limit: 50, default: "draft", null: false
    t.datetime "updated_at", null: false
    t.bigint "winner_variant_id"
    t.index ["control_version_id"], name: "index_ab_tests_on_control_version_id"
    t.index ["prompt_id", "status"], name: "index_ab_tests_on_prompt_id_and_status"
    t.index ["prompt_id"], name: "index_ab_tests_on_prompt_id"
    t.index ["prompt_id"], name: "index_ab_tests_one_running_per_prompt", unique: true, where: "((status)::text = 'running'::text)"
    t.index ["status"], name: "index_ab_tests_on_status"
    t.index ["winner_variant_id"], name: "index_ab_tests_on_winner_variant_id"
  end

  create_table "account_memberships", force: :cascade do |t|
    t.bigint "account_id", null: false
    t.datetime "created_at", null: false
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
    t.integer "default_max_tokens_per_run", default: 10000000, null: false
    t.string "name", null: false
    t.string "slug", null: false
    t.datetime "updated_at", null: false
    t.index ["slug"], name: "index_accounts_on_slug", unique: true
  end

  create_table "agent_run_anomalies", force: :cascade do |t|
    t.bigint "agent_run_id", null: false
    t.string "anomaly_type", limit: 50, null: false
    t.float "baseline_mean", null: false
    t.float "baseline_standard_deviation", null: false
    t.datetime "created_at", null: false
    t.float "deviation_factor", null: false
    t.text "message"
    t.string "metric_name", limit: 50, null: false
    t.float "metric_value", null: false
    t.bigint "project_id", null: false
    t.string "severity", limit: 20, null: false
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

  create_table "agent_run_phases", force: :cascade do |t|
    t.bigint "agent_run_id", null: false
    t.datetime "created_at", null: false
    t.integer "duration_seconds", default: 0, null: false
    t.datetime "finished_at", null: false
    t.jsonb "metadata", default: {}, null: false
    t.string "phase_group", limit: 50, null: false
    t.string "phase_key", limit: 100, null: false
    t.datetime "started_at", null: false
    t.string "status", limit: 50, default: "completed", null: false
    t.datetime "updated_at", null: false
    t.index ["agent_run_id", "started_at"], name: "index_agent_run_phases_on_agent_run_id_and_started_at"
    t.index ["agent_run_id"], name: "index_agent_run_phases_on_agent_run_id"
    t.index ["phase_group", "started_at"], name: "index_agent_run_phases_on_phase_group_and_started_at"
    t.index ["phase_key", "started_at"], name: "index_agent_run_phases_on_phase_key_and_started_at"
    t.check_constraint "duration_seconds >= 0", name: "agent_run_phases_duration_seconds_non_negative"
    t.check_constraint "finished_at >= started_at", name: "agent_run_phases_finished_at_after_started_at"
  end

  create_table "agent_runs", force: :cascade do |t|
    t.string "agent_type", limit: 50, null: false
    t.string "auth_provider", limit: 50
    t.boolean "auto_pick", default: false, null: false
    t.float "avg_cpu_percent"
    t.decimal "avg_memory_bytes", precision: 20, scale: 4
    t.string "base_commit_sha", limit: 40
    t.string "branch_name", limit: 255
    t.datetime "completed_at"
    t.string "container_id", limit: 128
    t.integer "container_metrics_count", default: 0, null: false
    t.datetime "container_retained_until"
    t.integer "cost_cents", default: 0
    t.boolean "count_toward_draft_review_round", default: false, null: false
    t.datetime "created_at", null: false
    t.integer "created_issue_number"
    t.string "created_issue_url", limit: 500
    t.text "custom_prompt"
    t.string "diagnosis_issue_url", limit: 500
    t.string "diagnosis_status", limit: 50
    t.integer "duration_seconds"
    t.text "error_message"
    t.integer "expected_draft_review_count"
    t.string "final_provider", limit: 50
    t.string "goal", limit: 50, default: "create_pr", null: false
    t.jsonb "guardrail_context"
    t.string "guardrail_violation_type", limit: 50
    t.bigint "issue_id"
    t.integer "iterations", default: 0
    t.jsonb "mcp_server_snapshot", default: [], null: false
    t.string "parent_workflow_id", limit: 255
    t.datetime "paused_at"
    t.float "peak_cpu_percent"
    t.bigint "peak_memory_bytes"
    t.bigint "project_id", null: false
    t.bigint "prompt_version_id"
    t.bigint "provider_id"
    t.integer "provider_switches", default: 0, null: false
    t.jsonb "providers_attempted", default: [], null: false
    t.string "proxy_token", limit: 64
    t.integer "pull_request_number"
    t.string "pull_request_url", limit: 500
    t.datetime "rate_limited_until"
    t.string "result_commit_sha", limit: 40
    t.datetime "review_posted_at"
    t.string "review_url", limit: 500
    t.jsonb "service_container_ids", default: []
    t.jsonb "service_environment", default: {}
    t.integer "source_pull_request_number"
    t.integer "stale_requeue_count", default: 0, null: false
    t.datetime "started_at"
    t.string "status", limit: 50, default: "pending", null: false
    t.string "temporal_run_id", limit: 255
    t.string "temporal_workflow_id", limit: 255
    t.string "token_limit_status", limit: 50
    t.integer "tokens_input", default: 0
    t.integer "tokens_output", default: 0
    t.string "trigger_type", limit: 50, default: "automatic", null: false
    t.datetime "updated_at", null: false
    t.string "worktree_path", limit: 500
    t.index ["created_at"], name: "index_agent_runs_on_created_at"
    t.index ["guardrail_violation_type"], name: "index_agent_runs_on_guardrail_violation_type", where: "(guardrail_violation_type IS NOT NULL)"
    t.index ["issue_id"], name: "index_agent_runs_on_issue_id"
    t.index ["parent_workflow_id"], name: "index_agent_runs_on_parent_workflow_id"
    t.index ["project_id", "goal"], name: "index_agent_runs_on_project_id_and_goal"
    t.index ["project_id", "issue_id"], name: "idx_agent_runs_unique_active_issue", unique: true, where: "((issue_id IS NOT NULL) AND ((status)::text = ANY ((ARRAY['queued'::character varying, 'pending'::character varying, 'running'::character varying, 'paused'::character varying])::text[])))"
    t.index ["project_id", "source_pull_request_number", "goal"], name: "idx_agent_runs_unique_active_pr", unique: true, where: "((source_pull_request_number IS NOT NULL) AND ((status)::text = ANY ((ARRAY['queued'::character varying, 'pending'::character varying, 'running'::character varying, 'paused'::character varying])::text[])))"
    t.index ["project_id", "status", "completed_at"], name: "index_agent_runs_on_project_status_completed_at"
    t.index ["project_id", "status"], name: "index_agent_runs_on_project_id_and_status"
    t.index ["project_id"], name: "index_agent_runs_on_project_id"
    t.index ["prompt_version_id"], name: "index_agent_runs_on_prompt_version_id"
    t.index ["provider_id"], name: "index_agent_runs_on_provider_id"
    t.index ["proxy_token"], name: "index_agent_runs_on_proxy_token", unique: true
    t.index ["status"], name: "index_agent_runs_on_status"
    t.index ["temporal_workflow_id"], name: "index_agent_runs_on_temporal_workflow_id"
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

  create_table "cost_budgets", force: :cascade do |t|
    t.datetime "alert_sent_at"
    t.integer "alert_threshold_percent", default: 80, null: false
    t.string "budget_type", limit: 50, null: false
    t.datetime "created_at", null: false
    t.integer "current_usage_cents", default: 0, null: false
    t.string "enforcement_mode", limit: 20, default: "alert", null: false
    t.integer "grace_buffer_percent", default: 0, null: false
    t.integer "limit_cents", null: false
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

  create_table "github_tokens", force: :cascade do |t|
    t.jsonb "accessible_repositories", default: [], null: false
    t.bigint "account_id", null: false
    t.datetime "created_at", null: false
    t.bigint "created_by_id"
    t.datetime "expires_at"
    t.datetime "last_used_at"
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
    t.datetime "updated_at", null: false
    t.index ["depends_on_issue_id"], name: "index_issue_dependencies_on_depends_on_issue_id"
    t.index ["issue_id", "depends_on_issue_id"], name: "idx_issue_dependencies_unique", unique: true
    t.index ["issue_id", "depends_on_owner", "depends_on_repo", "depends_on_number"], name: "idx_issue_deps_external_unique", unique: true, where: "(depends_on_owner IS NOT NULL)"
    t.index ["issue_id"], name: "index_issue_dependencies_on_issue_id"
    t.check_constraint "depends_on_issue_id IS NOT NULL AND depends_on_owner IS NULL AND depends_on_repo IS NULL AND depends_on_number IS NULL OR depends_on_issue_id IS NULL AND NULLIF(depends_on_owner::text, ''::text) IS NOT NULL AND NULLIF(depends_on_repo::text, ''::text) IS NOT NULL AND depends_on_number > 0", name: "issue_dependencies_depends_on_xor"
  end

  create_table "issues", force: :cascade do |t|
    t.boolean "auto_continue_paused", default: false, null: false
    t.text "body"
    t.datetime "created_at", null: false
    t.integer "draft_review_count", default: 0, null: false
    t.datetime "github_created_at", null: false
    t.string "github_creator_login"
    t.bigint "github_issue_id", null: false
    t.integer "github_number", null: false
    t.string "github_state", null: false
    t.datetime "github_updated_at", null: false
    t.boolean "is_pull_request", default: false, null: false
    t.jsonb "labels", default: [], null: false
    t.string "paid_state", default: "new", null: false
    t.bigint "parent_issue_id"
    t.integer "pr_followup_count", default: 0, null: false
    t.string "pr_review_phase", default: "draft", null: false
    t.bigint "project_id", null: false
    t.string "source", default: "github", null: false
    t.string "title", limit: 1000, null: false
    t.datetime "updated_at", null: false
    t.index ["github_creator_login"], name: "index_issues_on_github_creator_login"
    t.index ["labels"], name: "index_issues_on_labels_gin_open_issues", where: "((is_pull_request = false) AND ((github_state)::text = 'open'::text))", using: :gin
    t.index ["labels"], name: "index_issues_on_labels_gin_open_prs", where: "((is_pull_request = true) AND ((github_state)::text = 'open'::text))", using: :gin
    t.index ["parent_issue_id"], name: "index_issues_on_parent_issue_id"
    t.index ["project_id", "github_issue_id"], name: "index_issues_on_project_id_and_github_issue_id", unique: true
    t.index ["project_id", "paid_state"], name: "index_issues_on_project_id_and_paid_state"
    t.index ["project_id", "pr_review_phase"], name: "idx_issues_pr_review_phase", where: "((is_pull_request = true) AND ((github_state)::text = 'open'::text))"
    t.index ["project_id", "source", "github_state"], name: "idx_issues_on_project_source_state"
    t.index ["project_id"], name: "index_issues_on_project_id"
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
    t.string "category", limit: 50, default: "general", null: false
    t.integer "context_window"
    t.datetime "created_at", null: false
    t.string "display_name", null: false
    t.string "family", limit: 100
    t.decimal "input_cost_per_million", precision: 10, scale: 4
    t.integer "max_output_tokens"
    t.jsonb "metadata", default: {}, null: false
    t.string "model_id", null: false
    t.decimal "output_cost_per_million", precision: 10, scale: 4
    t.string "provider", limit: 50, null: false
    t.boolean "supports_json_output", default: false, null: false
    t.boolean "supports_tools", default: false, null: false
    t.boolean "supports_vision", default: false, null: false
    t.string "tier", limit: 10
    t.datetime "updated_at", null: false
    t.index ["active"], name: "index_llm_models_on_active"
    t.index ["category"], name: "index_llm_models_on_category"
    t.index ["model_id"], name: "index_llm_models_on_model_id", unique: true
    t.index ["provider", "active"], name: "index_llm_models_on_provider_and_active"
    t.index ["provider"], name: "index_llm_models_on_provider"
    t.index ["tier"], name: "index_llm_models_on_tier"
    t.check_constraint "tier IS NULL OR (tier::text = ANY (ARRAY['low'::character varying, 'mid'::character varying, 'high'::character varying]::text[]))", name: "llm_models_tier_check"
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
    t.bigint "llm_model_id", null: false
    t.text "reasoning"
    t.integer "selection_duration_ms"
    t.string "selector_type", limit: 50, null: false
    t.datetime "updated_at", null: false
    t.index ["agent_run_id"], name: "index_model_selections_on_agent_run_id", unique: true
    t.index ["llm_model_id"], name: "index_model_selections_on_llm_model_id"
    t.index ["selector_type"], name: "index_model_selections_on_selector_type"
  end

  create_table "pre_commit_requirements", force: :cascade do |t|
    t.bigint "account_id", null: false
    t.string "check_type", limit: 50, default: "shell_command", null: false
    t.text "command", null: false
    t.datetime "created_at", null: false
    t.boolean "enabled", default: true, null: false
    t.string "failure_behavior", limit: 50, default: "block", null: false
    t.text "fix_command"
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

  create_table "project_baselines", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.datetime "last_calculated_at"
    t.float "mean", default: 0.0, null: false
    t.string "metric_name", limit: 50, null: false
    t.float "p95", default: 0.0, null: false
    t.bigint "project_id", null: false
    t.integer "sample_count", default: 0, null: false
    t.float "standard_deviation", default: 0.0, null: false
    t.datetime "updated_at", null: false
    t.index ["project_id", "metric_name"], name: "index_project_baselines_on_project_id_and_metric_name", unique: true
    t.index ["project_id"], name: "index_project_baselines_on_project_id"
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
    t.text "agent_co_author_trailer"
    t.jsonb "allowed_github_usernames", default: [], null: false
    t.boolean "auto_add_labels_enabled", default: true, null: false
    t.boolean "auto_fix_merge_conflicts", default: true, null: false
    t.boolean "auto_merge_enabled", default: false, null: false
    t.boolean "auto_pick_enabled", default: false, null: false
    t.boolean "auto_scan_prs", default: true, null: false
    t.boolean "auto_scan_security", default: false, null: false
    t.string "automation_label_name", default: "paid-automation", null: false
    t.boolean "automation_on_label_enabled", default: true, null: false
    t.integer "code_scanning_interval_hours", default: 72, null: false
    t.datetime "created_at", null: false
    t.bigint "created_by_id"
    t.string "default_branch", default: "main", null: false
    t.string "generated_label_name", default: "paid-generated", null: false
    t.bigint "github_id", null: false
    t.bigint "github_token_id", null: false
    t.string "knowledge_status", limit: 50, default: "pending", null: false
    t.jsonb "label_mappings", default: {}, null: false
    t.datetime "last_agent_run_at"
    t.datetime "last_code_scanning_scan_at"
    t.datetime "last_github_activity_at"
    t.datetime "last_polled_at"
    t.integer "max_draft_review_rounds", default: 10, null: false
    t.integer "max_execution_seconds", default: 1800, null: false
    t.integer "max_pr_followup_runs", default: 8, null: false
    t.integer "max_tokens_per_run"
    t.string "merge_method", default: "squash", null: false
    t.jsonb "model_preferences", default: {}, null: false
    t.string "name", null: false
    t.string "owner", null: false
    t.string "owner_reviewer_login"
    t.integer "poll_interval_seconds", default: 60, null: false
    t.jsonb "pr_action_labels", default: [], null: false
    t.boolean "pr_aggregation_enabled", default: false, null: false
    t.string "repo", null: false
    t.jsonb "review_settings", default: {}, null: false
    t.jsonb "security_alert_types", default: ["code_scanning"], null: false
    t.string "security_severity_threshold", default: "high", null: false
    t.integer "token_limit_warning_threshold", default: 80, null: false
    t.bigint "total_cost_cents", default: 0, null: false
    t.bigint "total_tokens_used", default: 0, null: false
    t.datetime "updated_at", null: false
    t.text "webhook_secret"
    t.index ["account_id", "active"], name: "index_projects_on_account_id_and_active"
    t.index ["account_id", "github_id"], name: "index_projects_on_account_id_and_github_id", unique: true
    t.index ["account_id", "last_agent_run_at"], name: "index_projects_on_account_id_and_last_agent_run_at"
    t.index ["account_id", "last_github_activity_at"], name: "index_projects_on_account_id_and_last_github_activity_at"
    t.index ["account_id"], name: "index_projects_on_account_id"
    t.index ["created_by_id"], name: "index_projects_on_created_by_id"
    t.index ["github_token_id"], name: "index_projects_on_github_token_id"
    t.index ["owner", "repo"], name: "index_projects_on_owner_and_repo"
  end

  create_table "prompt_versions", force: :cascade do |t|
    t.decimal "avg_iterations", precision: 4, scale: 2
    t.decimal "avg_quality_score", precision: 4, scale: 2
    t.text "change_notes"
    t.datetime "created_at", null: false
    t.string "created_by", limit: 50
    t.bigint "created_by_user_id"
    t.bigint "parent_version_id"
    t.bigint "prompt_id", null: false
    t.text "system_prompt"
    t.text "template", null: false
    t.integer "usage_count", default: 0, null: false
    t.jsonb "variables", default: [], null: false
    t.integer "version", null: false
    t.index ["created_by_user_id"], name: "index_prompt_versions_on_created_by_user_id"
    t.index ["parent_version_id"], name: "index_prompt_versions_on_parent_version_id"
    t.index ["prompt_id", "version"], name: "index_prompt_versions_on_prompt_id_and_version", unique: true
    t.index ["prompt_id"], name: "index_prompt_versions_on_prompt_id"
  end

  create_table "prompts", force: :cascade do |t|
    t.bigint "account_id"
    t.boolean "active", default: true, null: false
    t.string "category", limit: 50, null: false
    t.datetime "created_at", null: false
    t.bigint "current_version_id"
    t.text "description"
    t.string "name", limit: 255, null: false
    t.bigint "project_id"
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
    t.string "name", limit: 100, null: false
    t.datetime "updated_at", null: false
    t.bigint "user_id", null: false
    t.index ["user_id", "api_service_type"], name: "index_provider_api_keys_on_user_id_and_api_service_type"
    t.index ["user_id", "name"], name: "index_provider_api_keys_on_user_id_and_name", unique: true
    t.index ["user_id"], name: "index_provider_api_keys_on_user_id"
  end

  create_table "provider_states", force: :cascade do |t|
    t.datetime "circuit_opened_at"
    t.string "circuit_state", limit: 20, default: "closed", null: false
    t.datetime "created_at", null: false
    t.integer "failure_count", default: 0, null: false
    t.string "provider_name", limit: 50, null: false
    t.datetime "rate_limited_until"
    t.datetime "updated_at", null: false
    t.bigint "user_id", null: false
    t.index ["user_id", "provider_name"], name: "index_provider_states_on_user_id_and_provider_name", unique: true
  end

  create_table "providers", force: :cascade do |t|
    t.string "auth_type", limit: 20, default: "subscription", null: false
    t.jsonb "config", default: {}, null: false
    t.datetime "created_at", null: false
    t.boolean "enabled_for_agent_runs", default: true, null: false
    t.boolean "enabled_for_fallback", default: true, null: false
    t.string "fallback_role", limit: 30, default: "standard", null: false
    t.string "name", limit: 100, default: "", null: false
    t.bigint "provider_api_key_id"
    t.string "provider_key", limit: 50, null: false
    t.jsonb "tier_model_ids", default: {}, null: false
    t.datetime "updated_at", null: false
    t.bigint "user_id", null: false
    t.index ["auth_type"], name: "index_providers_on_auth_type"
    t.index ["provider_api_key_id"], name: "index_providers_on_provider_api_key_id"
    t.index ["tier_model_ids"], name: "index_providers_on_tier_model_ids", using: :gin
    t.index ["user_id", "provider_key", "provider_api_key_id", "name"], name: "idx_providers_unique_api_key", unique: true, where: "((auth_type)::text = 'api_key'::text)"
    t.index ["user_id", "provider_key"], name: "idx_providers_unique_subscription", unique: true, where: "((auth_type)::text = 'subscription'::text)"
    t.index ["user_id"], name: "index_providers_on_user_id"
    t.check_constraint "auth_type::text <> 'api_key'::text OR provider_api_key_id IS NOT NULL", name: "providers_api_key_requires_key"
    t.check_constraint "auth_type::text <> 'subscription'::text OR provider_api_key_id IS NULL AND fallback_role::text = 'standard'::text", name: "providers_subscription_invariants"
  end

  create_table "quality_metrics", force: :cascade do |t|
    t.bigint "agent_run_id", null: false
    t.decimal "composite_score", precision: 5, scale: 4
    t.datetime "created_at", null: false
    t.string "feedback_source", limit: 50
    t.jsonb "metadata", default: {}, null: false
    t.string "metric_type", limit: 20, null: false
    t.bigint "prompt_version_id"
    t.jsonb "scores", default: {}, null: false
    t.datetime "updated_at", null: false
    t.index ["agent_run_id", "metric_type"], name: "index_quality_metrics_on_agent_run_and_type", unique: true
    t.index ["agent_run_id"], name: "index_quality_metrics_on_agent_run_id"
    t.index ["composite_score"], name: "index_quality_metrics_on_composite_score"
    t.index ["created_at"], name: "index_quality_metrics_on_created_at"
    t.index ["metric_type"], name: "index_quality_metrics_on_metric_type"
    t.index ["prompt_version_id", "created_at"], name: "index_quality_metrics_on_prompt_version_and_created_at"
    t.index ["prompt_version_id"], name: "index_quality_metrics_on_prompt_version_id"
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
    t.float "avg_cpu_percent"
    t.decimal "avg_memory_bytes", precision: 20, scale: 4
    t.integer "container_metrics_count", default: 0, null: false
    t.datetime "created_at", null: false
    t.string "docker_container_id"
    t.jsonb "env", default: {}
    t.string "image", null: false
    t.string "name", null: false
    t.float "peak_cpu_percent"
    t.bigint "peak_memory_bytes"
    t.integer "port", null: false
    t.string "status", default: "stopped", null: false
    t.datetime "updated_at", null: false
    t.index ["name"], name: "index_service_containers_on_name", unique: true
  end

  create_table "style_guides", force: :cascade do |t|
    t.bigint "account_id"
    t.boolean "active", default: true, null: false
    t.text "compressed_content"
    t.jsonb "compression_metadata", default: {}, null: false
    t.datetime "created_at", null: false
    t.string "language", limit: 50
    t.string "name", limit: 255, null: false
    t.bigint "project_id"
    t.text "raw_content", null: false
    t.datetime "updated_at", null: false
    t.index ["account_id"], name: "index_style_guides_on_account_id"
    t.index ["active"], name: "index_style_guides_on_active"
    t.index ["language"], name: "index_style_guides_on_language"
    t.index ["name", "account_id"], name: "index_style_guides_on_name_account", unique: true, where: "((account_id IS NOT NULL) AND (project_id IS NULL))"
    t.index ["name", "project_id"], name: "index_style_guides_on_name_project", unique: true, where: "(project_id IS NOT NULL)"
    t.index ["name"], name: "index_style_guides_on_name_global", unique: true, where: "((account_id IS NULL) AND (project_id IS NULL))"
    t.index ["project_id"], name: "index_style_guides_on_project_id"
    t.check_constraint "project_id IS NULL OR account_id IS NOT NULL", name: "chk_style_guides_scope_consistency"
  end

  create_table "token_usages", force: :cascade do |t|
    t.bigint "agent_run_id", null: false
    t.integer "cost_cents", default: 0, null: false
    t.datetime "created_at", null: false
    t.integer "input_tokens", default: 0, null: false
    t.string "llm_model", limit: 100
    t.jsonb "metadata", default: {}, null: false
    t.integer "output_tokens", default: 0, null: false
    t.string "request_type", limit: 50, null: false
    t.datetime "updated_at", null: false
    t.index ["agent_run_id", "request_type"], name: "index_token_usages_on_agent_run_id_and_request_type"
    t.index ["created_at"], name: "index_token_usages_on_created_at"
    t.index ["llm_model"], name: "index_token_usages_on_llm_model"
    t.index ["request_type"], name: "index_token_usages_on_request_type"
  end

  create_table "user_settings", force: :cascade do |t|
    t.integer "agent_timeout_seconds", default: 3600, null: false
    t.jsonb "allowed_service_images", default: ["postgres:16", "redis:7-alpine", "selenium/standalone-chromium:latest"]
    t.integer "circuit_breaker_failure_threshold", default: 5, null: false
    t.integer "circuit_breaker_timeout_seconds", default: 300, null: false
    t.bigint "container_memory_bytes", default: 4294967296, null: false
    t.integer "container_timeout_seconds", default: 1800, null: false
    t.datetime "created_at", null: false
    t.string "default_agent_provider", default: "claude", null: false
    t.jsonb "default_allowed_github_usernames", default: [], null: false
    t.string "default_branch", default: "main", null: false
    t.integer "default_poll_interval_seconds", default: 60, null: false
    t.boolean "default_project_active", default: true, null: false
    t.boolean "fallback_enabled", default: false, null: false
    t.jsonb "fallback_providers", default: [], null: false
    t.integer "git_clone_timeout_seconds", default: 600, null: false
    t.integer "git_push_timeout_seconds", default: 60, null: false
    t.integer "github_token_cache_ttl_minutes", default: 60, null: false
    t.integer "issue_goal_idle_timeout_seconds", default: 120, null: false
    t.integer "issue_goal_timeout_seconds", default: 600, null: false
    t.integer "max_comment_length", default: 2000, null: false
    t.integer "max_concurrent_runs", default: 2, null: false
    t.integer "max_parallel_agents_per_project", default: 3, null: false
    t.integer "max_prompt_comments", default: 20, null: false
    t.integer "max_tokens_per_run", default: 10000000, null: false
    t.float "retry_base_delay", default: 1.0, null: false
    t.integer "retry_max_attempts", default: 3, null: false
    t.float "retry_max_delay", default: 60.0, null: false
    t.integer "review_goal_idle_timeout_seconds", default: 300, null: false
    t.integer "style_guide_max_raw_bytes", default: 100000, null: false
    t.integer "style_guide_max_raw_prompt_bytes", default: 8000, null: false
    t.integer "style_guide_max_total_bytes", default: 32000, null: false
    t.integer "token_validation_stale_minutes", default: 2, null: false
    t.datetime "updated_at", null: false
    t.bigint "user_id", null: false
    t.index ["user_id"], name: "index_user_settings_on_user_id", unique: true
  end

  create_table "users", force: :cascade do |t|
    t.bigint "account_id", null: false
    t.datetime "created_at", null: false
    t.string "email", default: "", null: false
    t.string "encrypted_password", default: "", null: false
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
  add_foreign_key "account_memberships", "accounts"
  add_foreign_key "account_memberships", "users"
  add_foreign_key "agent_run_anomalies", "agent_runs"
  add_foreign_key "agent_run_anomalies", "projects"
  add_foreign_key "agent_run_logs", "agent_runs", on_delete: :cascade
  add_foreign_key "agent_run_phases", "agent_runs", on_delete: :cascade
  add_foreign_key "agent_runs", "issues", on_delete: :nullify
  add_foreign_key "agent_runs", "projects", on_delete: :cascade
  add_foreign_key "agent_runs", "prompt_versions", on_delete: :nullify
  add_foreign_key "agent_runs", "providers", on_delete: :nullify
  add_foreign_key "collector_runs", "project_versions"
  add_foreign_key "container_metrics", "agent_runs", on_delete: :cascade
  add_foreign_key "cost_budgets", "projects", on_delete: :cascade
  add_foreign_key "decision_record_links", "decision_records", on_delete: :cascade
  add_foreign_key "decision_records", "agent_runs", on_delete: :nullify
  add_foreign_key "decision_records", "decision_records", column: "superseded_by_id", on_delete: :nullify
  add_foreign_key "decision_records", "issues", on_delete: :nullify
  add_foreign_key "decision_records", "projects", on_delete: :cascade
  add_foreign_key "github_tokens", "accounts"
  add_foreign_key "github_tokens", "users", column: "created_by_id"
  add_foreign_key "integration_credentials", "accounts"
  add_foreign_key "integration_credentials", "users", column: "created_by_id"
  add_foreign_key "issue_dependencies", "issues", column: "depends_on_issue_id", on_delete: :cascade
  add_foreign_key "issue_dependencies", "issues", on_delete: :cascade
  add_foreign_key "issues", "issues", column: "parent_issue_id"
  add_foreign_key "issues", "projects"
  add_foreign_key "knowledge_artifacts", "collector_runs", on_delete: :cascade
  add_foreign_key "knowledge_artifacts", "projects"
  add_foreign_key "knowledge_audit_events", "projects", on_delete: :cascade
  add_foreign_key "knowledge_chunks", "knowledge_artifacts", on_delete: :cascade
  add_foreign_key "knowledge_chunks", "projects"
  add_foreign_key "knowledge_links", "knowledge_chunks", column: "source_chunk_id", on_delete: :cascade
  add_foreign_key "knowledge_links", "knowledge_chunks", column: "target_chunk_id", on_delete: :cascade
  add_foreign_key "linear_tokens", "accounts"
  add_foreign_key "linear_tokens", "users", column: "created_by_id"
  add_foreign_key "mcp_server_definitions", "accounts"
  add_foreign_key "model_selections", "agent_runs", on_delete: :cascade
  add_foreign_key "model_selections", "llm_models"
  add_foreign_key "pre_commit_requirements", "accounts", on_delete: :cascade
  add_foreign_key "pre_commit_requirements", "projects", on_delete: :cascade
  add_foreign_key "pre_commit_requirements", "users", on_delete: :cascade
  add_foreign_key "project_baselines", "projects"
  add_foreign_key "project_mcp_servers", "mcp_server_definitions"
  add_foreign_key "project_mcp_servers", "projects"
  add_foreign_key "project_memberships", "projects"
  add_foreign_key "project_memberships", "users"
  add_foreign_key "project_service_containers", "projects", on_delete: :cascade
  add_foreign_key "project_service_containers", "service_containers", on_delete: :cascade
  add_foreign_key "project_versions", "projects"
  add_foreign_key "projects", "accounts"
  add_foreign_key "projects", "github_tokens"
  add_foreign_key "projects", "users", column: "created_by_id"
  add_foreign_key "prompt_versions", "prompt_versions", column: "parent_version_id", on_delete: :nullify
  add_foreign_key "prompt_versions", "prompts", on_delete: :cascade
  add_foreign_key "prompt_versions", "users", column: "created_by_user_id", on_delete: :nullify
  add_foreign_key "prompts", "accounts", on_delete: :cascade
  add_foreign_key "prompts", "projects", on_delete: :cascade
  add_foreign_key "prompts", "prompt_versions", column: "current_version_id", on_delete: :nullify
  add_foreign_key "provider_api_keys", "users", on_delete: :cascade
  add_foreign_key "provider_states", "users", on_delete: :cascade
  add_foreign_key "providers", "provider_api_keys", on_delete: :restrict
  add_foreign_key "providers", "users", on_delete: :cascade
  add_foreign_key "quality_metrics", "agent_runs", on_delete: :cascade
  add_foreign_key "quality_metrics", "prompt_versions", on_delete: :nullify
  add_foreign_key "service_container_metrics", "service_containers", on_delete: :cascade
  add_foreign_key "style_guides", "accounts", on_delete: :cascade
  add_foreign_key "style_guides", "projects", on_delete: :cascade
  add_foreign_key "token_usages", "agent_runs", on_delete: :cascade
  add_foreign_key "user_settings", "users"
  add_foreign_key "users", "accounts"
  add_foreign_key "workflow_states", "projects"
  add_foreign_key "worktrees", "agent_runs", on_delete: :nullify
  add_foreign_key "worktrees", "projects", on_delete: :cascade
end
