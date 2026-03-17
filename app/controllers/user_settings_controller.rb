# frozen_string_literal: true

# Settings infrastructure and UI for user-configurable defaults.
# Integration with project creation and agent runs is planned for a follow-up PR.
class UserSettingsController < ApplicationController
  before_action :set_user_setting

  def edit
    authorize @user_setting
  end

  def update
    authorize @user_setting

    if @user_setting.update(user_setting_params)
      redirect_to edit_user_settings_path, notice: "Settings saved successfully."
    else
      render :edit, status: :unprocessable_content
    end
  end

  private

  def set_user_setting
    @user_setting = current_user.settings
  end

  def user_setting_params
    permitted = params.require(:user_setting).permit(
      :default_poll_interval_seconds,
      :github_token_cache_ttl_minutes,
      :token_validation_stale_minutes,
      :agent_timeout_seconds,
      :default_agent_provider,
      :container_memory_gb,
      :max_concurrent_runs,
      :container_timeout_seconds,
      :default_branch,
      :default_project_active,
      :default_allowed_github_usernames_csv,
      :allowed_service_images_csv,
      :circuit_breaker_failure_threshold,
      :circuit_breaker_timeout_seconds,
      :retry_max_attempts,
      :retry_base_delay,
      :retry_max_delay,
      :fallback_enabled,
      :fallback_providers
    )

    # Parse fallback_providers from JSON string (from hidden field)
    if permitted[:fallback_providers].is_a?(String)
      parsed = JSON.parse(permitted[:fallback_providers])
      permitted[:fallback_providers] = if parsed.is_a?(Array)
        parsed.select { |provider| provider.is_a?(String) }
      else
        []
      end
    end

    permitted
  rescue JSON::ParserError
    permitted[:fallback_providers] = []
    permitted
  end
end
