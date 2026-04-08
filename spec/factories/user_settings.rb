# frozen_string_literal: true

FactoryBot.define do
  factory :user_setting do
    user

    default_poll_interval_seconds { 60 }
    github_token_cache_ttl_minutes { 60 }
    token_validation_stale_minutes { 2 }
    agent_timeout_seconds { 3600 }
    default_agent_provider { "claude" }
    container_memory_bytes { 4 * 1024 * 1024 * 1024 }
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
    allowed_service_images { [ "postgres:16", "redis:7-alpine", "selenium/standalone-chromium:latest" ] }
  end
end
