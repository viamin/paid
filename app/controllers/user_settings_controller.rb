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

    if permitted.key?(:fallback_providers)
      permitted[:fallback_providers] = UserSetting.normalize_fallback_providers_param(permitted[:fallback_providers])
    end

    permitted
  end
end
