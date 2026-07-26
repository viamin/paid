# frozen_string_literal: true

module Tools
  class UpdateUserSettings < BaseTool
    authorize :update?, ->(_args) { current_user.settings }

    PERMITTED_ATTRIBUTES = %i[
      theme_preference
      default_poll_interval_seconds
      github_token_cache_ttl_minutes
      token_validation_stale_minutes
      agent_timeout_seconds
      marketplace_auto_attach_enabled
      max_execution_seconds
      default_agent_runner
      container_memory_gb
      run_concurrency_mode
      max_concurrent_runs
      container_timeout_seconds
      default_branch
      default_project_active
      default_allowed_github_usernames_csv
      allowed_service_images_csv
      max_tokens_per_run
      issue_goal_timeout_seconds
      issue_goal_idle_timeout_seconds
      review_goal_idle_timeout_seconds
      git_clone_timeout_seconds
      git_unshallow_timeout_seconds
      git_push_timeout_seconds
      max_prompt_comments
      max_comment_length
      style_guide_max_raw_bytes
      style_guide_max_total_bytes
      style_guide_max_raw_prompt_bytes
      circuit_breaker_failure_threshold
      circuit_breaker_timeout_seconds
      retry_max_attempts
      retry_base_delay
      retry_max_delay
      max_issues_per_page
      max_prs_per_page
      fallback_enabled
      fallback_runners
      kb_embedding_runner
      kb_embedding_fallback_runners
      kb_chat_runner
      kb_chat_fallback_runners
      auto_pick_skip_labels
    ].freeze

    def self.tool_name = "update_user_settings"
    def self.write_operation? = true

    def self.description
      "Update the current user's settings."
    end

    def self.input_schema
      {
        type: "object",
        properties: {
          settings: { type: "object" },
          confirmed: { type: "boolean" }
        },
        required: %w[settings confirmed]
      }
    end

    def perform(settings:, confirmed:)
      raise ArgumentError, "Confirmation required: set confirmed=true to update user settings" unless confirmed
      raise ArgumentError, "settings must be an object" unless settings.is_a?(Hash)

      attrs = settings.symbolize_keys.slice(*PERMITTED_ATTRIBUTES)
      current_user.settings.update!(attrs)
      current_user.settings.reload.attributes.except("id", "user_id", "created_at", "updated_at", "log_data")
    end
  end
end
