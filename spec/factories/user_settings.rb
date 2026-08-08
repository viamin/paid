# frozen_string_literal: true

FactoryBot.define do
  factory :user_setting do
    user

    default_poll_interval_seconds { 60 }
    github_token_cache_ttl_minutes { 60 }
    token_validation_stale_minutes { 2 }
    agent_timeout_seconds { 5400 }
    agent_update_comment_mode { UserSetting::AGENT_UPDATE_COMMENT_MODE_DEFAULT }
    marketplace_auto_attach_enabled { false }
    default_agent_runner { "claude" }
    container_memory_bytes { 4 * 1024 * 1024 * 1024 }
    container_memory_limit_mode { UserSetting::CONTAINER_MEMORY_LIMIT_MODE_MANUAL }
    container_memory_auto_floor_bytes { UserSetting::DEFAULT_CONTAINER_MEMORY_AUTO_FLOOR_BYTES }
    container_memory_auto_ceiling_bytes { UserSetting::DEFAULT_CONTAINER_MEMORY_AUTO_CEILING_BYTES }
    run_concurrency_mode { UserSetting::RUN_CONCURRENCY_MODE_MANUAL }
    max_concurrent_runs { 2 }
    max_parallel_agents_per_project { 3 }
    container_timeout_seconds { 3600 }
    default_allowed_github_usernames { [] }
    default_branch { "main" }
    default_project_active { true }
    circuit_breaker_failure_threshold { 5 }
    circuit_breaker_timeout_seconds { 300 }
    retry_max_attempts { 3 }
    retry_base_delay { 1.0 }
    retry_max_delay { 60.0 }
    kb_embedding_runner { UserSetting::KB_EMBEDDING_RUNNER_DEFAULT }
    kb_embedding_fallback_runners { [] }
    kb_chat_runner { UserSetting::KB_CHAT_RUNNER_DEFAULT }
    kb_chat_fallback_runners { [] }
    issue_analysis_runner { "" }
    issue_analysis_fallback_runners { [] }
    allowed_service_images { [ "postgres:16", "redis:7-alpine", "selenium/standalone-chromium:latest" ] }
  end
end
