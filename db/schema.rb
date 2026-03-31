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

ActiveRecord::Schema[8.1].define(version: 2026_03_31_004430) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "citext"
  enable_extension "hstore"
  enable_extension "pg_catalog.plpgsql"
  enable_extension "pg_trgm"
  enable_extension "pgcrypto"
  enable_extension "uuid-ossp"

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
    t.string "name", null: false
    t.string "slug", null: false
    t.datetime "updated_at", null: false
    t.index ["slug"], name: "index_accounts_on_slug", unique: true
  end

  create_table "achievement_achievables", force: :cascade do |t|
    t.bigint "achievable_id"
    t.string "achievable_type"
    t.bigint "achievement_id"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["achievable_type", "achievable_id"], name: "index_achievement_achievables_on_achievable"
    t.index ["achievement_id"], name: "index_achievement_achievables_on_achievement_id"
  end

  create_table "achievements", force: :cascade do |t|
    t.datetime "created_at", precision: nil, null: false
    t.bigint "credential_id"
    t.text "details"
    t.date "end_date"
    t.bigint "experience_id"
    t.uuid "external_id", default: -> { "gen_random_uuid()" }, null: false
    t.bigint "hunt_id"
    t.text "notes"
    t.boolean "ongoing"
    t.integer "position"
    t.bigint "project_id"
    t.date "start_date"
    t.boolean "superceded"
    t.string "title"
    t.datetime "updated_at", precision: nil, null: false
    t.index ["credential_id"], name: "index_achievements_on_credential_id"
    t.index ["experience_id"], name: "index_achievements_on_experience_id"
    t.index ["external_id"], name: "index_achievements_on_external_id"
    t.index ["hunt_id"], name: "index_achievements_on_hunt_id"
    t.index ["project_id"], name: "index_achievements_on_project_id"
  end

  create_table "action_text_rich_texts", force: :cascade do |t|
    t.text "body"
    t.datetime "created_at", null: false
    t.string "name", null: false
    t.bigint "record_id", null: false
    t.string "record_type", null: false
    t.datetime "updated_at", null: false
    t.index ["record_type", "record_id", "name"], name: "index_action_text_rich_texts_uniqueness", unique: true
  end

  create_table "active_storage_attachments", force: :cascade do |t|
    t.bigint "blob_id", null: false
    t.datetime "created_at", null: false
    t.string "name", null: false
    t.bigint "record_id", null: false
    t.string "record_type", null: false
    t.index ["blob_id"], name: "index_active_storage_attachments_on_blob_id"
    t.index ["record_type", "record_id", "name", "blob_id"], name: "index_active_storage_attachments_uniqueness", unique: true
  end

  create_table "active_storage_blobs", force: :cascade do |t|
    t.bigint "byte_size", null: false
    t.string "checksum"
    t.string "content_type"
    t.datetime "created_at", null: false
    t.string "filename", null: false
    t.string "key", null: false
    t.text "metadata"
    t.string "service_name", null: false
    t.index ["key"], name: "index_active_storage_blobs_on_key", unique: true
  end

  create_table "active_storage_variant_records", force: :cascade do |t|
    t.bigint "blob_id", null: false
    t.string "variation_digest", null: false
    t.index ["blob_id", "variation_digest"], name: "index_active_storage_variant_records_uniqueness", unique: true
  end

  create_table "admins", id: :serial, force: :cascade do |t|
    t.datetime "created_at", precision: nil, null: false
    t.datetime "current_sign_in_at", precision: nil
    t.inet "current_sign_in_ip"
    t.string "direct_otp"
    t.datetime "direct_otp_sent_at", precision: nil
    t.string "doorkeeper_access_token"
    t.integer "doorkeeper_uid"
    t.string "email", default: "", null: false
    t.string "encrypted_otp_secret_key"
    t.string "encrypted_otp_secret_key_iv"
    t.string "encrypted_otp_secret_key_salt"
    t.string "encrypted_password", default: "", null: false
    t.integer "failed_attempts", default: 0, null: false
    t.datetime "last_seen", precision: nil
    t.datetime "last_sign_in_at", precision: nil
    t.inet "last_sign_in_ip"
    t.datetime "locked_at", precision: nil
    t.integer "second_factor_attempts_count", default: 0
    t.integer "sign_in_count", default: 0, null: false
    t.string "unlock_token"
    t.datetime "updated_at", precision: nil, null: false
    t.index ["email"], name: "index_admins_on_email", unique: true
    t.index ["encrypted_otp_secret_key"], name: "index_admins_on_encrypted_otp_secret_key", unique: true
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
    t.datetime "created_at", null: false
    t.integer "created_issue_number"
    t.string "created_issue_url", limit: 500
    t.text "custom_prompt"
    t.string "diagnosis_issue_url", limit: 500
    t.string "diagnosis_status", limit: 50
    t.integer "duration_seconds"
    t.text "error_message"
    t.string "final_provider", limit: 50
    t.string "goal", limit: 50, default: "create_pr", null: false
    t.bigint "issue_id"
    t.integer "iterations", default: 0
    t.jsonb "mcp_server_snapshot", default: [], null: false
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
    t.index ["project_id", "issue_id"], name: "idx_agent_runs_unique_active_issue", unique: true, where: "((issue_id IS NOT NULL) AND ((status)::text = ANY (ARRAY[('queued'::character varying)::text, ('pending'::character varying)::text, ('running'::character varying)::text])))"
    t.index ["project_id", "source_pull_request_number"], name: "idx_agent_runs_unique_active_pr", unique: true, where: "((source_pull_request_number IS NOT NULL) AND ((status)::text = ANY (ARRAY[('queued'::character varying)::text, ('pending'::character varying)::text, ('running'::character varying)::text])))"
    t.index ["project_id", "status"], name: "index_agent_runs_on_project_id_and_status"
    t.index ["project_id"], name: "index_agent_runs_on_project_id"
    t.index ["prompt_version_id"], name: "index_agent_runs_on_prompt_version_id"
    t.index ["provider_id"], name: "index_agent_runs_on_provider_id"
    t.index ["proxy_token"], name: "index_agent_runs_on_proxy_token", unique: true
    t.index ["status"], name: "index_agent_runs_on_status"
    t.index ["temporal_workflow_id"], name: "index_agent_runs_on_temporal_workflow_id"
  end

  create_table "ahoy_events", force: :cascade do |t|
    t.string "name"
    t.jsonb "properties"
    t.datetime "time", precision: nil
    t.bigint "user_id"
    t.bigint "visit_id"
    t.index ["name", "time"], name: "index_ahoy_events_on_name_and_time"
    t.index ["properties"], name: "index_ahoy_events_on_properties_jsonb_path_ops", opclass: :jsonb_path_ops, using: :gin
    t.index ["user_id"], name: "index_ahoy_events_on_user_id"
    t.index ["visit_id"], name: "index_ahoy_events_on_visit_id"
  end

  create_table "ahoy_messages", force: :cascade do |t|
    t.datetime "clicked_at", precision: nil
    t.string "mailer"
    t.datetime "opened_at", precision: nil
    t.datetime "sent_at", precision: nil
    t.text "subject"
    t.text "to"
    t.string "token"
    t.integer "user_id"
    t.string "user_type"
    t.string "utm_campaign"
    t.string "utm_medium"
    t.string "utm_source"
    t.index ["token"], name: "index_ahoy_messages_on_token"
    t.index ["user_id", "user_type"], name: "index_ahoy_messages_on_user_id_and_user_type"
  end

  create_table "ahoy_visits", force: :cascade do |t|
    t.string "browser"
    t.string "city"
    t.string "country"
    t.string "device_type"
    t.string "ip"
    t.text "landing_page"
    t.string "os"
    t.text "referrer"
    t.string "referring_domain"
    t.string "region"
    t.string "search_keyword"
    t.datetime "started_at", precision: nil
    t.text "user_agent"
    t.bigint "user_id"
    t.string "utm_campaign"
    t.string "utm_content"
    t.string "utm_medium"
    t.string "utm_source"
    t.string "utm_term"
    t.string "visit_token"
    t.string "visitor_token"
    t.index ["user_id"], name: "index_ahoy_visits_on_user_id"
    t.index ["visit_token"], name: "index_ahoy_visits_on_visit_token", unique: true
  end

  create_table "announcements", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.datetime "end_date"
    t.uuid "external_id", default: -> { "gen_random_uuid()" }, null: false
    t.string "headline", null: false
    t.integer "priority", default: 1, null: false
    t.boolean "published", default: false, null: false
    t.string "short_content"
    t.datetime "start_date"
    t.datetime "updated_at", null: false
    t.index ["external_id"], name: "index_announcements_on_external_id"
  end

  create_table "apartment_state_transitions", id: :serial, force: :cascade do |t|
    t.integer "apartment_id"
    t.datetime "created_at", precision: nil
    t.string "event"
    t.string "from"
    t.string "namespace"
    t.string "to"
    t.index ["apartment_id"], name: "index_apartment_state_transitions_on_apartment_id"
  end

  create_table "apartments", id: :serial, force: :cascade do |t|
    t.hstore "amenities"
    t.date "available"
    t.float "bathrooms"
    t.integer "bedrooms"
    t.datetime "created_at", precision: nil, null: false
    t.text "description"
    t.uuid "external_id", default: -> { "gen_random_uuid()" }, null: false
    t.integer "hunt_id"
    t.boolean "imported", default: false
    t.integer "monthly_rent"
    t.text "neighborhood"
    t.datetime "posted_at", precision: nil
    t.integer "size"
    t.string "slug"
    t.float "stat_html_ratio"
    t.float "stat_link_deviation"
    t.integer "state"
    t.text "title"
    t.string "token"
    t.datetime "updated_at", precision: nil, null: false
    t.text "url"
    t.index ["external_id"], name: "index_apartments_on_external_id"
    t.index ["hunt_id"], name: "index_apartments_on_hunt_id"
    t.index ["slug", "hunt_id"], name: "index_apartments_on_slug_and_hunt_id", unique: true
  end

  create_table "beta", id: :serial, force: :cascade do |t|
    t.boolean "active"
    t.string "body"
    t.datetime "created_at", precision: nil, null: false
    t.text "email"
    t.uuid "external_id", default: -> { "gen_random_uuid()" }, null: false
    t.bigint "hunter_id"
    t.string "name"
    t.integer "receive_count", default: 0
    t.float "stat_html_ratio"
    t.float "stat_link_deviation"
    t.integer "state"
    t.string "subject"
    t.datetime "updated_at", precision: nil, null: false
    t.index ["email"], name: "index_beta_on_email"
    t.index ["external_id"], name: "index_beta_on_external_id"
    t.index ["hunter_id"], name: "index_beta_on_hunter_id"
  end

  create_table "blazer_audits", force: :cascade do |t|
    t.datetime "created_at"
    t.string "data_source"
    t.bigint "query_id"
    t.text "statement"
    t.bigint "user_id"
    t.index ["query_id"], name: "index_blazer_audits_on_query_id"
    t.index ["user_id"], name: "index_blazer_audits_on_user_id"
  end

  create_table "blazer_checks", force: :cascade do |t|
    t.string "check_type"
    t.datetime "created_at", null: false
    t.bigint "creator_id"
    t.text "emails"
    t.datetime "last_run_at"
    t.text "message"
    t.bigint "query_id"
    t.string "schedule"
    t.text "slack_channels"
    t.string "state"
    t.datetime "updated_at", null: false
    t.index ["creator_id"], name: "index_blazer_checks_on_creator_id"
    t.index ["query_id"], name: "index_blazer_checks_on_query_id"
  end

  create_table "blazer_dashboard_queries", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "dashboard_id"
    t.integer "position"
    t.bigint "query_id"
    t.datetime "updated_at", null: false
    t.index ["dashboard_id"], name: "index_blazer_dashboard_queries_on_dashboard_id"
    t.index ["query_id"], name: "index_blazer_dashboard_queries_on_query_id"
  end

  create_table "blazer_dashboards", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "creator_id"
    t.string "name"
    t.datetime "updated_at", null: false
    t.index ["creator_id"], name: "index_blazer_dashboards_on_creator_id"
  end

  create_table "blazer_queries", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "creator_id"
    t.string "data_source"
    t.text "description"
    t.string "name"
    t.text "statement"
    t.string "status"
    t.datetime "updated_at", null: false
    t.index ["creator_id"], name: "index_blazer_queries_on_creator_id"
  end

  create_table "bookmarks", id: :serial, force: :cascade do |t|
    t.datetime "created_at", precision: nil, null: false
    t.uuid "external_id", default: -> { "gen_random_uuid()" }, null: false
    t.integer "hunt_id"
    t.text "notes"
    t.datetime "posted_at", precision: nil
    t.text "title"
    t.datetime "updated_at", precision: nil, null: false
    t.text "url"
    t.index ["external_id"], name: "index_bookmarks_on_external_id"
    t.index ["hunt_id"], name: "index_bookmarks_on_hunt_id"
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

  create_table "comments", force: :cascade do |t|
    t.bigint "author_id", null: false
    t.bigint "commentable_id", null: false
    t.string "commentable_type", null: false
    t.string "content"
    t.datetime "created_at", null: false
    t.uuid "external_id", default: -> { "gen_random_uuid()" }, null: false
    t.bigint "parent_id"
    t.string "parent_type"
    t.bigint "recipient_id", null: false
    t.uuid "thread_id"
    t.string "type"
    t.datetime "updated_at", null: false
    t.index ["author_id"], name: "index_comments_on_author_id"
    t.index ["commentable_type", "commentable_id"], name: "index_comments_on_commentable"
    t.index ["external_id"], name: "index_comments_on_external_id"
    t.index ["parent_id", "parent_type"], name: "index_comments_on_parent_id_and_parent_type"
    t.index ["recipient_id"], name: "index_comments_on_recipient_id"
    t.index ["thread_id"], name: "index_comments_on_thread_id"
    t.index ["type"], name: "index_comments_on_type"
  end

  create_table "contacts", id: :serial, force: :cascade do |t|
    t.text "address"
    t.text "city"
    t.text "company"
    t.integer "contact_category"
    t.integer "contact_type"
    t.text "country"
    t.datetime "created_at", precision: nil, null: false
    t.text "email"
    t.uuid "external_id", default: -> { "gen_random_uuid()" }, null: false
    t.integer "hunter_id"
    t.string "label"
    t.datetime "last_active_date", precision: nil
    t.text "name"
    t.bigint "network_id"
    t.bigint "parent_id"
    t.integer "phone"
    t.string "phone_number"
    t.text "phone_prefix"
    t.text "postal_code"
    t.string "province"
    t.bigint "resume_id"
    t.text "state"
    t.datetime "updated_at", precision: nil, null: false
    t.index ["email", "label", "contact_type", "hunter_id", "network_id", "parent_id"], name: "idx_on_email_label_contact_type_hunter_id_network_i_9cdfbf9e24", unique: true
    t.index ["external_id"], name: "index_contacts_on_external_id"
    t.index ["hunter_id"], name: "index_contacts_on_hunter_id"
    t.index ["network_id"], name: "index_contacts_on_network_id"
    t.index ["parent_id"], name: "index_contacts_on_parent_id"
    t.index ["resume_id"], name: "index_contacts_on_resume_id"
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
    t.integer "limit_cents", null: false
    t.datetime "period_started_at"
    t.bigint "project_id", null: false
    t.datetime "updated_at", null: false
    t.index ["project_id", "budget_type"], name: "index_cost_budgets_on_project_id_and_budget_type", unique: true
  end

  create_table "cover_letters", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.uuid "external_id"
    t.bigint "hunter_id", null: false
    t.bigint "job_id", null: false
    t.bigint "resume_id"
    t.string "slug"
    t.integer "state"
    t.string "title"
    t.datetime "updated_at", null: false
    t.index ["external_id"], name: "index_cover_letters_on_external_id"
    t.index ["hunter_id"], name: "index_cover_letters_on_hunter_id"
    t.index ["job_id"], name: "index_cover_letters_on_job_id"
    t.index ["resume_id"], name: "index_cover_letters_on_resume_id"
    t.index ["slug", "hunter_id"], name: "index_cover_letters_on_slug_and_hunter_id", unique: true
  end

  create_table "credentials", force: :cascade do |t|
    t.datetime "created_at", precision: nil, null: false
    t.integer "credential_type"
    t.integer "date_display", default: 0, null: false
    t.date "end_date"
    t.uuid "external_id", default: -> { "gen_random_uuid()" }, null: false
    t.text "institution"
    t.text "name"
    t.text "notes"
    t.integer "position"
    t.bigint "resume_id"
    t.date "start_date"
    t.datetime "updated_at", precision: nil, null: false
    t.index ["external_id"], name: "index_credentials_on_external_id"
    t.index ["resume_id"], name: "index_credentials_on_resume_id"
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

  create_table "decline_reasons", force: :cascade do |t|
    t.boolean "active", default: true, null: false
    t.string "category"
    t.datetime "created_at", null: false
    t.text "description"
    t.string "name"
    t.datetime "updated_at", null: false
    t.index ["name"], name: "index_decline_reasons_on_name", unique: true
  end

  create_table "details", force: :cascade do |t|
    t.datetime "created_at", precision: nil, null: false
    t.jsonb "data", default: {}
    t.bigint "extendable_id"
    t.string "extendable_type"
    t.datetime "updated_at", precision: nil, null: false
    t.index ["extendable_type", "extendable_id"], name: "index_details_on_extendable"
  end

  create_table "experiences", force: :cascade do |t|
    t.datetime "created_at", precision: nil, null: false
    t.integer "date_display", default: 0, null: false
    t.date "end_date"
    t.uuid "external_id", default: -> { "gen_random_uuid()" }, null: false
    t.string "location"
    t.text "organization"
    t.integer "position"
    t.bigint "resume_id"
    t.text "role"
    t.date "start_date"
    t.string "team"
    t.text "title"
    t.datetime "updated_at", precision: nil, null: false
    t.index ["external_id"], name: "index_experiences_on_external_id"
    t.index ["resume_id"], name: "index_experiences_on_resume_id"
  end

  create_table "field_test_memberships", force: :cascade do |t|
    t.boolean "converted", default: false, null: false
    t.datetime "created_at"
    t.string "experiment"
    t.string "participant_id"
    t.string "participant_type"
    t.string "variant"
    t.index ["experiment", "created_at"], name: "index_field_test_memberships_on_experiment_and_created_at"
    t.index ["participant_type", "participant_id", "experiment"], name: "index_field_test_memberships_on_participant", unique: true
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

  create_table "friendly_id_slugs", id: :serial, force: :cascade do |t|
    t.datetime "created_at", precision: nil
    t.string "scope"
    t.string "slug", null: false
    t.integer "sluggable_id", null: false
    t.string "sluggable_type", limit: 50
    t.index ["slug", "sluggable_type", "scope"], name: "index_friendly_id_slugs_on_slug_and_sluggable_type_and_scope", unique: true
    t.index ["sluggable_id"], name: "index_friendly_id_slugs_on_sluggable_id"
    t.index ["sluggable_type"], name: "index_friendly_id_slugs_on_sluggable_type"
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

  create_table "goals", force: :cascade do |t|
    t.string "action"
    t.string "action_type"
    t.boolean "active"
    t.datetime "created_at", precision: nil, null: false
    t.boolean "custom", default: false
    t.boolean "decision"
    t.datetime "due_at", precision: nil
    t.uuid "external_id", default: -> { "gen_random_uuid()" }, null: false
    t.bigint "hunt_id"
    t.string "next_step"
    t.bigint "owner_id"
    t.string "owner_type"
    t.integer "priority"
    t.integer "progress"
    t.string "prompt"
    t.string "result"
    t.string "subject"
    t.string "title"
    t.datetime "updated_at", precision: nil, null: false
    t.index ["external_id"], name: "index_goals_on_external_id"
    t.index ["hunt_id"], name: "index_goals_on_hunt_id"
    t.index ["owner_type", "owner_id"], name: "index_goals_on_owner"
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

  create_table "hunters", id: :serial, force: :cascade do |t|
    t.datetime "confirmation_sent_at", precision: nil
    t.string "confirmation_token"
    t.datetime "confirmed_at", precision: nil
    t.datetime "created_at", precision: nil, null: false
    t.datetime "current_sign_in_at", precision: nil
    t.inet "current_sign_in_ip"
    t.text "email", null: false
    t.string "encrypted_password", default: "", null: false
    t.uuid "external_id", default: -> { "gen_random_uuid()" }, null: false
    t.integer "goal_reminder_interval"
    t.uuid "jti", default: -> { "gen_random_uuid()" }
    t.text "landing_url"
    t.datetime "last_seen", precision: nil
    t.datetime "last_sign_in_at", precision: nil
    t.inet "last_sign_in_ip"
    t.string "passkey_id"
    t.text "referring_url"
    t.datetime "remember_created_at", precision: nil
    t.datetime "reset_password_sent_at", precision: nil
    t.string "reset_password_token"
    t.integer "sign_in_count", default: 0, null: false
    t.string "slug"
    t.integer "state"
    t.string "token"
    t.string "unconfirmed_email"
    t.datetime "updated_at", precision: nil, null: false
    t.index ["confirmation_token"], name: "index_hunters_on_confirmation_token", unique: true
    t.index ["email"], name: "index_hunters_on_email_unique", unique: true
    t.index ["external_id"], name: "index_hunters_on_external_id"
    t.index ["passkey_id"], name: "index_hunters_on_passkey_id", unique: true
    t.index ["reset_password_token"], name: "index_hunters_on_reset_password_token", unique: true
    t.index ["slug"], name: "index_hunters_on_slug"
  end

  create_table "hunts", id: :serial, force: :cascade do |t|
    t.boolean "active", default: true
    t.datetime "created_at", precision: nil, null: false
    t.string "created_via"
    t.date "date_ended"
    t.date "date_started"
    t.uuid "external_id", default: -> { "gen_random_uuid()" }, null: false
    t.integer "hunter_id"
    t.text "notes"
    t.string "prey_category"
    t.integer "prey_count", default: 0, null: false
    t.string "slug"
    t.integer "state"
    t.string "time_frame"
    t.string "title"
    t.string "token"
    t.datetime "updated_at", precision: nil, null: false
    t.index ["external_id"], name: "index_hunts_on_external_id"
    t.index ["hunter_id"], name: "index_hunts_on_hunter_id"
    t.index ["slug", "hunter_id"], name: "index_hunts_on_slug_and_hunter_id", unique: true
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

  create_table "invitations", force: :cascade do |t|
    t.datetime "accepted_at"
    t.datetime "created_at", null: false
    t.datetime "declined_at"
    t.datetime "expires_at"
    t.uuid "external_id", default: -> { "gen_random_uuid()" }, null: false
    t.bigint "hunt_id", null: false
    t.bigint "invitee_id", null: false
    t.bigint "inviter_id", null: false
    t.string "slug", null: false
    t.datetime "updated_at", null: false
    t.index ["external_id"], name: "index_invitations_on_external_id", unique: true
    t.index ["hunt_id"], name: "index_invitations_on_hunt_id"
    t.index ["invitee_id"], name: "index_invitations_on_invitee_id"
    t.index ["inviter_id"], name: "index_invitations_on_inviter_id"
    t.index ["slug", "inviter_id"], name: "index_invitations_on_slug_and_inviter_id", unique: true
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

  create_table "job_state_transitions", id: :serial, force: :cascade do |t|
    t.datetime "created_at", precision: nil
    t.string "event"
    t.string "from"
    t.integer "job_id"
    t.string "namespace"
    t.string "to"
    t.index ["job_id"], name: "index_job_state_transitions_on_job_id"
  end

  create_table "jobs", id: :serial, force: :cascade do |t|
    t.text "company"
    t.string "contract"
    t.text "contract_type"
    t.datetime "created_at", precision: nil, null: false
    t.text "custom_decline_reason"
    t.bigint "decline_reason_id"
    t.text "description"
    t.uuid "external_id", default: -> { "gen_random_uuid()" }, null: false
    t.integer "hunt_id"
    t.boolean "imported", default: false
    t.text "location"
    t.datetime "posted_at", precision: nil
    t.money "salary", scale: 2
    t.string "salary_range"
    t.string "slug"
    t.float "stat_html_ratio"
    t.float "stat_link_deviation"
    t.integer "state"
    t.text "title"
    t.string "token"
    t.datetime "updated_at", precision: nil, null: false
    t.text "url"
    t.index ["decline_reason_id"], name: "index_jobs_on_decline_reason_id"
    t.index ["external_id"], name: "index_jobs_on_external_id"
    t.index ["hunt_id"], name: "index_jobs_on_hunt_id"
    t.index ["slug", "hunt_id"], name: "index_jobs_on_slug_and_hunt_id", unique: true
  end

  create_table "jwt_blacklist", force: :cascade do |t|
    t.datetime "exp", precision: nil, default: "2022-05-02 17:43:26", null: false
    t.string "jti", null: false
    t.index ["jti"], name: "index_jwt_blacklist_on_jti"
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
    t.datetime "updated_at", null: false
    t.index ["active"], name: "index_llm_models_on_active"
    t.index ["category"], name: "index_llm_models_on_category"
    t.index ["model_id"], name: "index_llm_models_on_model_id", unique: true
    t.index ["provider", "active"], name: "index_llm_models_on_provider_and_active"
    t.index ["provider"], name: "index_llm_models_on_provider"
  end

  create_table "login_activities", force: :cascade do |t|
    t.string "city"
    t.string "context"
    t.string "country"
    t.datetime "created_at"
    t.string "failure_reason"
    t.string "identity"
    t.string "ip"
    t.float "latitude"
    t.float "longitude"
    t.text "referrer"
    t.string "region"
    t.string "scope"
    t.string "strategy"
    t.boolean "success", default: false, null: false
    t.text "user_agent"
    t.bigint "user_id"
    t.string "user_type"
    t.index ["identity"], name: "index_login_activities_on_identity"
    t.index ["ip"], name: "index_login_activities_on_ip"
    t.index ["user_type", "user_id"], name: "index_login_activities_on_user"
  end

  create_table "maintenance_tasks_runs", force: :cascade do |t|
    t.text "arguments"
    t.text "backtrace"
    t.datetime "created_at", null: false
    t.string "cursor"
    t.datetime "ended_at", precision: nil
    t.string "error_class"
    t.string "error_message"
    t.string "job_id"
    t.integer "lock_version", default: 0, null: false
    t.text "metadata"
    t.datetime "started_at", precision: nil
    t.string "status", default: "enqueued", null: false
    t.string "task_name", null: false
    t.bigint "tick_count", default: 0, null: false
    t.bigint "tick_total"
    t.float "time_running", default: 0.0, null: false
    t.datetime "updated_at", null: false
    t.index ["job_id"], name: "index_maintenance_tasks_runs_on_job_id"
    t.index ["task_name", "status", "created_at"], name: "index_maintenance_tasks_runs", order: { created_at: :desc }
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

  create_table "message_templates", force: :cascade do |t|
    t.boolean "active"
    t.integer "category"
    t.jsonb "content"
    t.datetime "created_at", precision: nil, null: false
    t.uuid "external_id", default: -> { "gen_random_uuid()" }, null: false
    t.string "media"
    t.string "title"
    t.datetime "updated_at", precision: nil, null: false
    t.index ["external_id"], name: "index_message_templates_on_external_id"
  end

  create_table "messages", id: :serial, force: :cascade do |t|
    t.text "body"
    t.integer "conversation_id"
    t.datetime "created_at", precision: nil, null: false
    t.uuid "external_id", default: -> { "gen_random_uuid()" }, null: false
    t.text "headers"
    t.text "media"
    t.integer "prey_id"
    t.string "prey_type"
    t.datetime "received", precision: nil
    t.citext "recipients", array: true
    t.citext "sender"
    t.string "sparkpost_message"
    t.integer "state"
    t.text "subject"
    t.citext "to", array: true
    t.datetime "updated_at", precision: nil, null: false
    t.index ["conversation_id"], name: "index_messages_on_conversation_id"
    t.index ["external_id"], name: "index_messages_on_external_id"
    t.index ["prey_id"], name: "index_messages_on_prey_id"
    t.index ["recipients"], name: "index_messages_on_recipients"
    t.index ["sender"], name: "index_messages_on_sender"
    t.index ["sparkpost_message"], name: "index_messages_on_sparkpost_message", unique: true
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

  create_table "multi_joins", force: :cascade do |t|
    t.bigint "achievement_id"
    t.bigint "contact_id"
    t.datetime "created_at", null: false
    t.bigint "credential_id"
    t.bigint "experience_id"
    t.bigint "goal_id"
    t.bigint "hunt_id"
    t.bigint "job_id"
    t.bigint "project_id"
    t.bigint "skill_id"
    t.datetime "updated_at", null: false
    t.index ["achievement_id"], name: "index_multi_joins_on_achievement_id"
    t.index ["contact_id"], name: "index_multi_joins_on_contact_id"
    t.index ["credential_id"], name: "index_multi_joins_on_credential_id"
    t.index ["experience_id"], name: "index_multi_joins_on_experience_id"
    t.index ["goal_id"], name: "index_multi_joins_on_goal_id"
    t.index ["hunt_id"], name: "index_multi_joins_on_hunt_id"
    t.index ["job_id"], name: "index_multi_joins_on_job_id"
    t.index ["project_id"], name: "index_multi_joins_on_project_id"
    t.index ["skill_id"], name: "index_multi_joins_on_skill_id"
  end

  create_table "networks", force: :cascade do |t|
    t.integer "contacts_count", default: 0, null: false
    t.datetime "created_at", precision: nil, null: false
    t.uuid "external_id", default: -> { "gen_random_uuid()" }, null: false
    t.bigint "hunter_id"
    t.jsonb "settings"
    t.datetime "updated_at", precision: nil, null: false
    t.index ["external_id"], name: "index_networks_on_external_id"
    t.index ["hunter_id"], name: "index_networks_on_hunter_id"
  end

  create_table "notable_jobs", force: :cascade do |t|
    t.datetime "created_at"
    t.text "job"
    t.string "job_id"
    t.text "note"
    t.string "note_type"
    t.string "queue"
    t.float "queued_time"
    t.float "runtime"
  end

  create_table "notable_requests", force: :cascade do |t|
    t.text "action"
    t.datetime "created_at"
    t.string "ip"
    t.text "note"
    t.string "note_type"
    t.text "params"
    t.text "referrer"
    t.string "request_id"
    t.float "request_time"
    t.integer "status"
    t.text "url"
    t.text "user_agent"
    t.bigint "user_id"
    t.string "user_type"
    t.index ["user_type", "user_id"], name: "index_notable_requests_on_user"
  end

  create_table "passkey_credentials", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "external_id", null: false
    t.bigint "hunter_id", null: false
    t.string "nickname", null: false
    t.string "public_key", null: false
    t.integer "sign_count", default: 0, null: false
    t.datetime "updated_at", null: false
    t.index ["external_id"], name: "index_passkey_credentials_on_external_id", unique: true
    t.index ["hunter_id"], name: "index_passkey_credentials_on_hunter_id"
    t.index ["nickname", "hunter_id"], name: "index_passkey_credentials_on_nickname_and_hunter_id", unique: true
  end

  create_table "pay_charges", force: :cascade do |t|
    t.integer "amount", null: false
    t.integer "amount_refunded"
    t.integer "application_fee_amount"
    t.datetime "created_at", null: false
    t.string "currency"
    t.bigint "customer_id", null: false
    t.jsonb "data"
    t.jsonb "metadata"
    t.string "processor_id", null: false
    t.string "stripe_account"
    t.bigint "subscription_id"
    t.string "type"
    t.datetime "updated_at", null: false
    t.index ["customer_id", "processor_id"], name: "index_pay_charges_on_customer_id_and_processor_id", unique: true
    t.index ["subscription_id"], name: "index_pay_charges_on_subscription_id"
  end

  create_table "pay_customers", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.jsonb "data"
    t.boolean "default", default: false, null: false
    t.datetime "deleted_at", precision: nil
    t.bigint "owner_id"
    t.string "owner_type"
    t.string "processor", null: false
    t.string "processor_id"
    t.string "stripe_account"
    t.string "type"
    t.datetime "updated_at", null: false
    t.index ["owner_type", "owner_id", "deleted_at"], name: "pay_customer_owner_index", unique: true
    t.index ["processor", "processor_id"], name: "index_pay_customers_on_processor_and_processor_id", unique: true
  end

  create_table "pay_merchants", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.jsonb "data"
    t.boolean "default", default: false, null: false
    t.bigint "owner_id"
    t.string "owner_type"
    t.string "processor", null: false
    t.string "processor_id"
    t.string "type"
    t.datetime "updated_at", null: false
    t.index ["owner_type", "owner_id", "processor"], name: "index_pay_merchants_on_owner_type_and_owner_id_and_processor"
  end

  create_table "pay_payment_methods", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "customer_id", null: false
    t.jsonb "data"
    t.boolean "default", default: false, null: false
    t.string "payment_method_type"
    t.string "processor_id", null: false
    t.string "stripe_account"
    t.string "type"
    t.datetime "updated_at", null: false
    t.index ["customer_id", "processor_id"], name: "index_pay_payment_methods_on_customer_id_and_processor_id", unique: true
  end

  create_table "pay_subscriptions", force: :cascade do |t|
    t.decimal "application_fee_percent", precision: 8, scale: 2
    t.datetime "created_at", null: false
    t.datetime "current_period_end", precision: nil
    t.datetime "current_period_start", precision: nil
    t.bigint "customer_id", null: false
    t.jsonb "data"
    t.datetime "ends_at", precision: nil
    t.jsonb "metadata"
    t.boolean "metered", default: false, null: false
    t.string "name", null: false
    t.string "pause_behavior"
    t.datetime "pause_resumes_at", precision: nil
    t.datetime "pause_starts_at", precision: nil
    t.string "payment_method_id"
    t.string "processor_id", null: false
    t.string "processor_plan", null: false
    t.integer "quantity", default: 1, null: false
    t.string "status", null: false
    t.string "stripe_account"
    t.datetime "trial_ends_at", precision: nil
    t.string "type"
    t.datetime "updated_at", null: false
    t.index ["customer_id", "processor_id"], name: "index_pay_subscriptions_on_customer_id_and_processor_id", unique: true
    t.index ["metered"], name: "index_pay_subscriptions_on_metered"
    t.index ["pause_starts_at"], name: "index_pay_subscriptions_on_pause_starts_at"
  end

  create_table "pay_webhooks", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.jsonb "event"
    t.string "event_type"
    t.string "processor"
    t.datetime "updated_at", null: false
  end

  create_table "pghero_query_stats", force: :cascade do |t|
    t.bigint "calls"
    t.datetime "captured_at", precision: nil
    t.text "database"
    t.text "query"
    t.bigint "query_hash"
    t.float "total_time"
    t.text "user"
    t.index ["database", "captured_at"], name: "index_pghero_query_stats_on_database_and_captured_at"
  end

  create_table "plan_steps", force: :cascade do |t|
    t.boolean "active", default: true
    t.datetime "created_at", precision: nil, null: false
    t.uuid "external_id", default: -> { "gen_random_uuid()" }, null: false
    t.bigint "parent_id"
    t.bigint "plan_id"
    t.integer "priority"
    t.integer "step"
    t.string "step_type"
    t.datetime "target", precision: nil
    t.string "title"
    t.string "track"
    t.datetime "updated_at", precision: nil, null: false
    t.index ["external_id"], name: "index_plan_steps_on_external_id"
    t.index ["parent_id"], name: "index_plan_steps_on_parent_id"
    t.index ["plan_id"], name: "index_plan_steps_on_plan_id"
  end

  create_table "plan_templates", force: :cascade do |t|
    t.jsonb "content"
    t.datetime "created_at", precision: nil, null: false
    t.uuid "external_id", default: -> { "gen_random_uuid()" }, null: false
    t.bigint "plan_step_id"
    t.string "template_type"
    t.string "title"
    t.datetime "updated_at", precision: nil, null: false
    t.index ["external_id"], name: "index_plan_templates_on_external_id"
    t.index ["plan_step_id"], name: "index_plan_templates_on_plan_step_id"
  end

  create_table "plans", force: :cascade do |t|
    t.boolean "active"
    t.datetime "created_at", precision: nil, null: false
    t.uuid "external_id", default: -> { "gen_random_uuid()" }, null: false
    t.bigint "hunt_id"
    t.datetime "target", precision: nil
    t.string "title"
    t.datetime "updated_at", precision: nil, null: false
    t.index ["external_id"], name: "index_plans_on_external_id"
    t.index ["hunt_id"], name: "index_plans_on_hunt_id"
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
    t.integer "max_pr_followup_runs", default: 8, null: false
    t.integer "max_security_fix_runs", default: 3, null: false
    t.string "merge_method", default: "squash", null: false
    t.jsonb "model_preferences", default: {}, null: false
    t.string "name", null: false
    t.string "owner", null: false
    t.string "owner_reviewer_login"
    t.integer "poll_interval_seconds", default: 60, null: false
    t.jsonb "pr_action_labels", default: [], null: false
    t.string "repo", null: false
    t.jsonb "security_alert_types", default: ["dependabot", "code_scanning"], null: false
    t.string "security_severity_threshold", default: "high", null: false
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
    t.jsonb "compatible_providers", default: [], null: false
    t.datetime "created_at", null: false
    t.string "name", limit: 100, null: false
    t.datetime "updated_at", null: false
    t.bigint "user_id", null: false
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
    t.datetime "updated_at", null: false
    t.bigint "user_id", null: false
    t.index ["auth_type"], name: "index_providers_on_auth_type"
    t.index ["provider_api_key_id"], name: "index_providers_on_provider_api_key_id"
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

  create_table "reminders", id: :serial, force: :cascade do |t|
    t.boolean "active", default: true
    t.datetime "created_at", precision: nil, null: false
    t.datetime "due", precision: nil
    t.uuid "external_id", default: -> { "gen_random_uuid()" }, null: false
    t.integer "interval", default: 1
    t.integer "original_id"
    t.integer "original_state"
    t.string "original_type"
    t.boolean "repeating", default: false
    t.datetime "updated_at", precision: nil, null: false
    t.index ["external_id"], name: "index_reminders_on_external_id"
    t.index ["original_id"], name: "index_reminders_on_original_id"
  end

  create_table "resume_feedback_requests", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.uuid "external_id", default: -> { "gen_random_uuid()" }, null: false
    t.string "message"
    t.bigint "resume_id", null: false
    t.string "subject"
    t.bigint "teammate_id", null: false
    t.datetime "updated_at", null: false
    t.index ["external_id"], name: "index_resume_feedback_requests_on_external_id", unique: true
    t.index ["resume_id"], name: "index_resume_feedback_requests_on_resume_id"
    t.index ["teammate_id"], name: "index_resume_feedback_requests_on_teammate_id"
  end

  create_table "resume_skills", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.integer "position"
    t.bigint "resume_id"
    t.bigint "skill_id"
    t.datetime "updated_at", null: false
    t.index ["resume_id"], name: "index_resume_skills_on_resume_id"
    t.index ["skill_id"], name: "index_resume_skills_on_skill_id"
  end

  create_table "resumes", force: :cascade do |t|
    t.bigint "contact_id"
    t.datetime "created_at", precision: nil, null: false
    t.uuid "external_id", default: -> { "gen_random_uuid()" }, null: false
    t.bigint "hunt_id"
    t.bigint "job_id"
    t.bigint "restored_snapshot_id"
    t.string "slug"
    t.integer "state"
    t.text "summary"
    t.text "title"
    t.datetime "updated_at", precision: nil, null: false
    t.index ["contact_id"], name: "index_resumes_on_contact_id"
    t.index ["external_id"], name: "index_resumes_on_external_id"
    t.index ["hunt_id"], name: "index_resumes_on_hunt_id"
    t.index ["job_id"], name: "index_resumes_on_job_id"
    t.index ["restored_snapshot_id"], name: "index_resumes_on_restored_snapshot_id"
    t.index ["slug", "hunt_id"], name: "index_resumes_on_slug_and_hunt_id", unique: true
  end

  create_table "role_assignments", force: :cascade do |t|
    t.integer "added_by"
    t.datetime "created_at", null: false
    t.bigint "hunter_id", null: false
    t.bigint "role_id", null: false
    t.datetime "updated_at", null: false
    t.index ["hunter_id"], name: "index_role_assignments_on_hunter_id"
    t.index ["role_id"], name: "index_role_assignments_on_role_id"
  end

  create_table "roles", id: :serial, force: :cascade do |t|
    t.datetime "created_at", precision: nil, null: false
    t.string "name"
    t.integer "resource_id"
    t.string "resource_type"
    t.datetime "updated_at", precision: nil, null: false
    t.index ["name", "resource_type", "resource_id"], name: "index_roles_on_name_and_resource_type_and_resource_id"
    t.index ["resource_type", "resource_id"], name: "index_roles_on_resource"
  end

  create_table "scraped_data", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.uuid "external_id", default: -> { "gen_random_uuid()" }, null: false
    t.bigint "fetchable_id"
    t.string "fetchable_type"
    t.string "hostname"
    t.datetime "last_scrape_attempted_at", precision: nil
    t.integer "last_scrape_status"
    t.datetime "last_scraped_successfully_at", precision: nil
    t.text "raw_content"
    t.datetime "updated_at", null: false
    t.string "url"
    t.index ["external_id"], name: "index_scraped_data_on_external_id", unique: true
    t.index ["fetchable_type", "fetchable_id"], name: "index_scraped_data_on_fetchable"
    t.index ["url"], name: "index_scraped_data_on_url"
  end

  create_table "search_steps", id: :serial, force: :cascade do |t|
    t.datetime "created_at", precision: nil, null: false
    t.uuid "external_id", default: -> { "gen_random_uuid()" }, null: false
    t.integer "search_strategy_id"
    t.string "search_term"
    t.integer "step"
    t.integer "step_type"
    t.datetime "updated_at", precision: nil, null: false
    t.index ["external_id"], name: "index_search_steps_on_external_id"
    t.index ["search_strategy_id"], name: "index_search_steps_on_search_strategy_id"
  end

  create_table "search_strategies", id: :serial, force: :cascade do |t|
    t.datetime "created_at", precision: nil, null: false
    t.citext "domain"
    t.uuid "external_id", default: -> { "gen_random_uuid()" }, null: false
    t.datetime "last_attempted", precision: nil
    t.datetime "last_successful", precision: nil
    t.string "post_process_command"
    t.string "prey_attribute"
    t.citext "prey_type"
    t.string "provider"
    t.integer "steps_count", default: 0, null: false
    t.datetime "updated_at", precision: nil, null: false
    t.integer "version"
    t.index ["domain", "prey_type", "prey_attribute"], name: "by_domain_and_type_and_prey", unique: true
    t.index ["external_id"], name: "index_search_strategies_on_external_id"
  end

  create_table "seed_migration_data_migrations", id: :serial, force: :cascade do |t|
    t.datetime "migrated_on", precision: nil
    t.integer "runtime"
    t.string "version"
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

  create_table "settings", id: :serial, force: :cascade do |t|
    t.datetime "created_at", precision: nil, null: false
    t.integer "daily_time", default: 8
    t.integer "day_of_week", default: 6
    t.boolean "disable_emails", default: false
    t.uuid "external_id", default: -> { "gen_random_uuid()" }, null: false
    t.integer "hunt_reminder_interval", default: 10
    t.integer "hunter_id"
    t.integer "prey_reminder_interval", default: 5
    t.bigint "restored_snapshot_id"
    t.string "timezone", default: "Pacific Time (US & Canada)"
    t.datetime "updated_at", precision: nil, null: false
    t.index ["external_id"], name: "index_settings_on_external_id"
    t.index ["hunter_id"], name: "index_settings_on_hunter_id"
    t.index ["restored_snapshot_id"], name: "index_settings_on_restored_snapshot_id"
  end

  create_table "skills", force: :cascade do |t|
    t.datetime "created_at", precision: nil, null: false
    t.uuid "external_id", default: -> { "gen_random_uuid()" }, null: false
    t.bigint "hunt_id"
    t.text "name"
    t.integer "position"
    t.bigint "resume_id"
    t.datetime "updated_at", precision: nil, null: false
    t.index ["external_id"], name: "index_skills_on_external_id"
    t.index ["hunt_id"], name: "index_skills_on_hunt_id"
    t.index ["name", "hunt_id"], name: "index_skills_on_name_and_hunt_id", unique: true
    t.index ["resume_id"], name: "index_skills_on_resume_id"
  end

  create_table "snapshot_items", force: :cascade do |t|
    t.string "child_group_name"
    t.datetime "created_at", null: false
    t.bigint "item_id", null: false
    t.string "item_type", null: false
    t.json "object", null: false
    t.bigint "snapshot_id", null: false
    t.index ["item_type", "item_id"], name: "index_snapshot_items_on_item"
    t.index ["snapshot_id", "item_id", "item_type"], name: "index_snapshot_items_on_snapshot_id_and_item_id_and_item_type", unique: true
  end

  create_table "snapshots", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "identifier"
    t.bigint "item_id", null: false
    t.string "item_type", null: false
    t.json "metadata"
    t.bigint "user_id"
    t.string "user_type"
    t.index ["created_at"], name: "index_snapshots_on_created_at"
    t.index ["identifier", "item_id", "item_type"], name: "index_snapshots_on_identifier_and_item_id_and_item_type", unique: true
    t.index ["item_type", "item_id"], name: "index_snapshots_on_item"
    t.index ["user_type", "user_id"], name: "index_snapshots_on_user"
  end

  create_table "stats_emails", id: :serial, force: :cascade do |t|
    t.datetime "created_at", precision: nil
    t.text "email"
    t.text "from"
    t.integer "prey", default: 0
    t.index ["prey"], name: "index_stats_emails_on_prey"
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

  create_table "suggestions", force: :cascade do |t|
    t.bigint "author_id", null: false
    t.text "content"
    t.datetime "created_at", null: false
    t.uuid "external_id", default: -> { "gen_random_uuid()" }, null: false
    t.bigint "recipient_id", null: false
    t.string "replacement"
    t.bigint "suggestable_id", null: false
    t.string "suggestable_type", null: false
    t.uuid "thread_id"
    t.datetime "updated_at", null: false
    t.index ["author_id"], name: "index_suggestions_on_author_id"
    t.index ["external_id"], name: "index_suggestions_on_external_id"
    t.index ["recipient_id"], name: "index_suggestions_on_recipient_id"
    t.index ["suggestable_type", "suggestable_id"], name: "index_suggestions_on_suggestable"
    t.index ["thread_id"], name: "index_suggestions_on_thread_id"
  end

  create_table "taggings", id: :serial, force: :cascade do |t|
    t.string "context", limit: 128
    t.datetime "created_at", precision: nil
    t.integer "tag_id"
    t.integer "taggable_id"
    t.string "taggable_type"
    t.integer "tagger_id"
    t.string "tagger_type"
    t.index ["tag_id", "taggable_id", "taggable_type", "context", "tagger_id", "tagger_type"], name: "taggings_idx", unique: true
    t.index ["taggable_type", "taggable_id"], name: "index_taggings_on_taggable"
    t.index ["tagger_type", "tagger_id"], name: "index_taggings_on_tagger"
  end

  create_table "tags", id: :serial, force: :cascade do |t|
    t.string "name"
    t.integer "taggings_count", default: 0
    t.index ["name"], name: "index_tags_on_name", unique: true
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

  create_table "urls", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "linkable_id", null: false
    t.string "linkable_type", null: false
    t.integer "position"
    t.string "provider"
    t.datetime "updated_at", null: false
    t.string "url", null: false
    t.index ["linkable_type", "linkable_id"], name: "index_urls_on_linkable"
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
  add_foreign_key "achievements", "credentials"
  add_foreign_key "achievements", "experiences"
  add_foreign_key "achievements", "hunts"
  add_foreign_key "active_storage_attachments", "active_storage_blobs", column: "blob_id"
  add_foreign_key "active_storage_variant_records", "active_storage_blobs", column: "blob_id"
  add_foreign_key "agent_run_logs", "agent_runs", on_delete: :cascade
  add_foreign_key "agent_run_phases", "agent_runs", on_delete: :cascade
  add_foreign_key "agent_runs", "issues", on_delete: :nullify
  add_foreign_key "agent_runs", "projects", on_delete: :cascade
  add_foreign_key "agent_runs", "prompt_versions", on_delete: :nullify
  add_foreign_key "agent_runs", "providers", on_delete: :nullify
  add_foreign_key "apartment_state_transitions", "apartments"
  add_foreign_key "collector_runs", "project_versions"
  add_foreign_key "comments", "comments", column: "parent_id"
  add_foreign_key "comments", "hunters", column: "author_id"
  add_foreign_key "comments", "hunters", column: "recipient_id"
  add_foreign_key "contacts", "networks"
  add_foreign_key "contacts", "resumes"
  add_foreign_key "container_metrics", "agent_runs", on_delete: :cascade
  add_foreign_key "cost_budgets", "projects", on_delete: :cascade
  add_foreign_key "cover_letters", "hunters"
  add_foreign_key "cover_letters", "jobs"
  add_foreign_key "cover_letters", "resumes"
  add_foreign_key "credentials", "resumes"
  add_foreign_key "decision_record_links", "decision_records", on_delete: :cascade
  add_foreign_key "decision_records", "agent_runs", on_delete: :nullify
  add_foreign_key "decision_records", "decision_records", column: "superseded_by_id", on_delete: :nullify
  add_foreign_key "decision_records", "issues", on_delete: :nullify
  add_foreign_key "decision_records", "projects", on_delete: :cascade
  add_foreign_key "experiences", "resumes"
  add_foreign_key "github_tokens", "accounts"
  add_foreign_key "github_tokens", "users", column: "created_by_id"
  add_foreign_key "hunts", "hunters"
  add_foreign_key "integration_credentials", "accounts"
  add_foreign_key "integration_credentials", "users", column: "created_by_id"
  add_foreign_key "invitations", "hunters", column: "invitee_id"
  add_foreign_key "invitations", "hunters", column: "inviter_id"
  add_foreign_key "invitations", "hunts"
  add_foreign_key "issue_dependencies", "issues", column: "depends_on_issue_id", on_delete: :cascade
  add_foreign_key "issue_dependencies", "issues", on_delete: :cascade
  add_foreign_key "issues", "issues", column: "parent_issue_id"
  add_foreign_key "issues", "projects"
  add_foreign_key "job_state_transitions", "jobs"
  add_foreign_key "jobs", "decline_reasons"
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
  add_foreign_key "networks", "hunters"
  add_foreign_key "passkey_credentials", "hunters"
  add_foreign_key "pay_charges", "pay_customers", column: "customer_id"
  add_foreign_key "pay_charges", "pay_subscriptions", column: "subscription_id"
  add_foreign_key "pay_payment_methods", "pay_customers", column: "customer_id"
  add_foreign_key "pay_subscriptions", "pay_customers", column: "customer_id"
  add_foreign_key "plan_steps", "plan_steps", column: "parent_id"
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
  add_foreign_key "resume_feedback_requests", "hunters", column: "teammate_id"
  add_foreign_key "resume_feedback_requests", "resumes"
  add_foreign_key "resumes", "jobs"
  add_foreign_key "resumes", "snapshots", column: "restored_snapshot_id"
  add_foreign_key "role_assignments", "hunters"
  add_foreign_key "role_assignments", "roles"
  add_foreign_key "search_steps", "search_strategies"
  add_foreign_key "service_container_metrics", "service_containers", on_delete: :cascade
  add_foreign_key "settings", "snapshots", column: "restored_snapshot_id"
  add_foreign_key "skills", "hunts"
  add_foreign_key "skills", "resumes"
  add_foreign_key "style_guides", "accounts", on_delete: :cascade
  add_foreign_key "style_guides", "projects", on_delete: :cascade
  add_foreign_key "suggestions", "hunters", column: "author_id"
  add_foreign_key "suggestions", "hunters", column: "recipient_id"
  add_foreign_key "token_usages", "agent_runs", on_delete: :cascade
  add_foreign_key "user_settings", "users"
  add_foreign_key "users", "accounts"
  add_foreign_key "workflow_states", "projects"
  add_foreign_key "worktrees", "agent_runs", on_delete: :nullify
  add_foreign_key "worktrees", "projects", on_delete: :cascade
end
