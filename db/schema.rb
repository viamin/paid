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

ActiveRecord::Schema[8.1].define(version: 2026_03_07_130000) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"

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
    t.string "name", null: false
    t.string "slug", null: false
    t.datetime "updated_at", null: false
    t.index ["slug"], name: "index_accounts_on_slug", unique: true
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

  create_table "agent_runs", force: :cascade do |t|
    t.string "agent_type", limit: 50, null: false
    t.string "auth_provider", limit: 50
    t.string "base_commit_sha", limit: 40
    t.string "branch_name", limit: 255
    t.datetime "completed_at"
    t.string "container_id", limit: 128
    t.integer "cost_cents", default: 0
    t.datetime "created_at", null: false
    t.integer "created_issue_number"
    t.string "created_issue_url", limit: 500
    t.text "custom_prompt"
    t.integer "duration_seconds"
    t.text "error_message"
    t.string "final_provider", limit: 50
    t.string "goal", limit: 50, default: "create_pr", null: false
    t.bigint "issue_id"
    t.integer "iterations", default: 0
    t.bigint "project_id", null: false
    t.bigint "prompt_version_id"
    t.integer "provider_switches", default: 0, null: false
    t.jsonb "providers_attempted", default: [], null: false
    t.string "proxy_token", limit: 64
    t.integer "pull_request_number"
    t.string "pull_request_url", limit: 500
    t.string "result_commit_sha", limit: 40
    t.jsonb "service_container_ids", default: []
    t.jsonb "service_environment", default: {}
    t.integer "source_pull_request_number"
    t.datetime "started_at"
    t.string "status", limit: 50, default: "pending", null: false
    t.string "temporal_run_id", limit: 255
    t.string "temporal_workflow_id", limit: 255
    t.integer "tokens_input", default: 0
    t.integer "tokens_output", default: 0
    t.string "trigger_type", limit: 50, default: "automatic", null: false
    t.datetime "updated_at", null: false
    t.string "worktree_path", limit: 500
    t.index ["created_at"], name: "index_agent_runs_on_created_at"
    t.index ["issue_id"], name: "index_agent_runs_on_issue_id"
    t.index ["project_id", "goal"], name: "index_agent_runs_on_project_id_and_goal"
    t.index ["project_id", "issue_id"], name: "idx_agent_runs_unique_active_issue", unique: true, where: "((issue_id IS NOT NULL) AND ((status)::text = ANY ((ARRAY['queued'::character varying, 'pending'::character varying, 'running'::character varying])::text[])))"
    t.index ["project_id", "source_pull_request_number"], name: "idx_agent_runs_unique_active_pr", unique: true, where: "((source_pull_request_number IS NOT NULL) AND ((status)::text = ANY ((ARRAY['queued'::character varying, 'pending'::character varying, 'running'::character varying])::text[])))"
    t.index ["project_id", "status"], name: "index_agent_runs_on_project_id_and_status"
    t.index ["project_id"], name: "index_agent_runs_on_project_id"
    t.index ["prompt_version_id"], name: "index_agent_runs_on_prompt_version_id"
    t.index ["proxy_token"], name: "index_agent_runs_on_proxy_token", unique: true
    t.index ["status"], name: "index_agent_runs_on_status"
    t.index ["temporal_workflow_id"], name: "index_agent_runs_on_temporal_workflow_id"
  end

  create_table "github_tokens", force: :cascade do |t|
    t.jsonb "accessible_repositories", default: [], null: false
    t.bigint "account_id", null: false
    t.datetime "created_at", null: false
    t.bigint "created_by_id"
    t.datetime "expires_at"
    t.datetime "last_used_at"
    t.string "name", null: false
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

  create_table "issue_dependencies", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "depends_on_issue_id", null: false
    t.bigint "issue_id", null: false
    t.datetime "updated_at", null: false
    t.index ["depends_on_issue_id"], name: "index_issue_dependencies_on_depends_on_issue_id"
    t.index ["issue_id", "depends_on_issue_id"], name: "idx_issue_dependencies_unique", unique: true
    t.index ["issue_id"], name: "index_issue_dependencies_on_issue_id"
  end

  create_table "issues", force: :cascade do |t|
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
    t.string "title", limit: 1000, null: false
    t.datetime "updated_at", null: false
    t.index ["github_creator_login"], name: "index_issues_on_github_creator_login"
    t.index ["labels"], name: "index_issues_on_labels_gin_open_prs", where: "((is_pull_request = true) AND ((github_state)::text = 'open'::text))", using: :gin
    t.index ["parent_issue_id"], name: "index_issues_on_parent_issue_id"
    t.index ["project_id", "github_issue_id"], name: "index_issues_on_project_id_and_github_issue_id", unique: true
    t.index ["project_id", "paid_state"], name: "index_issues_on_project_id_and_paid_state"
    t.index ["project_id", "pr_review_phase"], name: "idx_issues_pr_review_phase", where: "((is_pull_request = true) AND ((github_state)::text = 'open'::text))"
    t.index ["project_id"], name: "index_issues_on_project_id"
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

  create_table "projects", force: :cascade do |t|
    t.bigint "account_id", null: false
    t.boolean "active", default: true, null: false
    t.jsonb "allowed_github_usernames", default: [], null: false
    t.boolean "auto_fix_merge_conflicts", default: false, null: false
    t.boolean "auto_scan_prs", default: true, null: false
    t.datetime "created_at", null: false
    t.bigint "created_by_id"
    t.string "default_branch", default: "main", null: false
    t.bigint "github_id", null: false
    t.bigint "github_token_id", null: false
    t.jsonb "label_mappings", default: {}, null: false
    t.datetime "last_agent_run_at"
    t.datetime "last_github_activity_at"
    t.datetime "last_polled_at"
    t.integer "max_draft_review_rounds", default: 10, null: false
    t.integer "max_pr_followup_runs", default: 8, null: false
    t.string "merge_method", default: "squash", null: false
    t.string "name", null: false
    t.string "owner", null: false
    t.string "owner_reviewer_login"
    t.integer "poll_interval_seconds", default: 60, null: false
    t.jsonb "pr_action_labels", default: [], null: false
    t.string "repo", null: false
    t.bigint "total_cost_cents", default: 0, null: false
    t.bigint "total_tokens_used", default: 0, null: false
    t.datetime "updated_at", null: false
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
    t.jsonb "config", default: {}, null: false
    t.datetime "created_at", null: false
    t.boolean "enabled_for_agent_runs", default: true, null: false
    t.boolean "enabled_for_fallback", default: true, null: false
    t.string "provider_key", limit: 50, null: false
    t.datetime "updated_at", null: false
    t.bigint "user_id", null: false
    t.index ["user_id", "provider_key"], name: "index_providers_on_user_id_and_provider_key", unique: true
    t.index ["user_id"], name: "index_providers_on_user_id"
  end

  create_table "service_containers", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "docker_container_id"
    t.jsonb "env", default: {}
    t.string "image", null: false
    t.string "name", null: false
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

  create_table "user_settings", force: :cascade do |t|
    t.integer "agent_timeout_seconds", default: 3600, null: false
    t.jsonb "allowed_service_images", default: ["postgres:16", "redis:7-alpine", "selenium/standalone-chromium:latest"]
    t.integer "circuit_breaker_failure_threshold", default: 5, null: false
    t.integer "circuit_breaker_timeout_seconds", default: 300, null: false
    t.integer "container_cpu_quota", default: 200000, null: false
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
    t.integer "github_token_cache_ttl_minutes", default: 60, null: false
    t.float "retry_base_delay", default: 1.0, null: false
    t.integer "retry_max_attempts", default: 3, null: false
    t.float "retry_max_delay", default: 60.0, null: false
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

  add_foreign_key "account_memberships", "accounts"
  add_foreign_key "account_memberships", "users"
  add_foreign_key "agent_run_logs", "agent_runs", on_delete: :cascade
  add_foreign_key "agent_runs", "issues", on_delete: :nullify
  add_foreign_key "agent_runs", "projects", on_delete: :cascade
  add_foreign_key "agent_runs", "prompt_versions", on_delete: :nullify
  add_foreign_key "github_tokens", "accounts"
  add_foreign_key "github_tokens", "users", column: "created_by_id"
  add_foreign_key "issue_dependencies", "issues", column: "depends_on_issue_id", on_delete: :cascade
  add_foreign_key "issue_dependencies", "issues", on_delete: :cascade
  add_foreign_key "issues", "issues", column: "parent_issue_id"
  add_foreign_key "issues", "projects"
  add_foreign_key "project_memberships", "projects"
  add_foreign_key "project_memberships", "users"
  add_foreign_key "project_service_containers", "projects", on_delete: :cascade
  add_foreign_key "project_service_containers", "service_containers", on_delete: :cascade
  add_foreign_key "projects", "accounts"
  add_foreign_key "projects", "github_tokens"
  add_foreign_key "projects", "users", column: "created_by_id"
  add_foreign_key "prompt_versions", "prompt_versions", column: "parent_version_id", on_delete: :nullify
  add_foreign_key "prompt_versions", "prompts", on_delete: :cascade
  add_foreign_key "prompt_versions", "users", column: "created_by_user_id", on_delete: :nullify
  add_foreign_key "prompts", "accounts", on_delete: :cascade
  add_foreign_key "prompts", "projects", on_delete: :cascade
  add_foreign_key "prompts", "prompt_versions", column: "current_version_id", on_delete: :nullify
  add_foreign_key "provider_states", "users", on_delete: :cascade
  add_foreign_key "providers", "users", on_delete: :cascade
  add_foreign_key "style_guides", "accounts", on_delete: :cascade
  add_foreign_key "style_guides", "projects", on_delete: :cascade
  add_foreign_key "user_settings", "users"
  add_foreign_key "users", "accounts"
  add_foreign_key "workflow_states", "projects"
  add_foreign_key "worktrees", "agent_runs", on_delete: :nullify
  add_foreign_key "worktrees", "projects", on_delete: :cascade
end
