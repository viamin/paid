# frozen_string_literal: true

class UserSettingsController < ApplicationController
  before_action :set_user_setting

  def edit
    authorize @user_setting
  end

  def update
    authorize @user_setting

    update_params = user_setting_params
    if params.dig(:user_setting, :default_allowed_github_usernames_csv)
      update_params = update_params.merge(
        default_allowed_github_usernames: parse_usernames_csv
      )
    end

    if @user_setting.update(update_params)
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
    params.require(:user_setting).permit(
      :default_poll_interval_seconds,
      :github_token_cache_ttl_minutes,
      :token_validation_stale_minutes,
      :agent_timeout_seconds,
      :default_agent_provider,
      :container_memory_bytes,
      :container_cpu_quota,
      :container_timeout_seconds,
      :default_branch,
      :default_project_active,
      :circuit_breaker_failure_threshold,
      :circuit_breaker_timeout_seconds,
      :retry_max_attempts,
      :retry_base_delay,
      :retry_max_delay
    )
  end

  def parse_usernames_csv
    params.dig(:user_setting, :default_allowed_github_usernames_csv)
      .to_s.split(",").map(&:strip).reject(&:blank?).uniq
  end
end
