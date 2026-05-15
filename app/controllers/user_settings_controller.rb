# frozen_string_literal: true

# Settings infrastructure and UI for user-configurable defaults.
class UserSettingsController < ApplicationController
  before_action :set_user_setting

  def edit
    authorize @user_setting
  end

  def update
    authorize @user_setting

    if @user_setting.update(user_setting_params)
      respond_to do |format|
        format.html { redirect_to edit_user_settings_path, status: :see_other, notice: "Settings saved successfully." }
        format.turbo_stream { redirect_to edit_user_settings_path, status: :see_other, notice: "Settings saved successfully." }
        format.json { head :ok }
      end
    else
      respond_to do |format|
        format.html { render :edit, status: :unprocessable_content }
        format.turbo_stream { render :edit, formats: :html, status: :unprocessable_content }
        format.json { render json: { errors: @user_setting.errors }, status: :unprocessable_content }
      end
    end
  end

  private

  def set_user_setting
    @user_setting = current_user.settings
  end

  def user_setting_params
    raw_params = params.require(:user_setting)
    permitted = raw_params.permit(
      :theme_preference,
      :default_poll_interval_seconds,
      :github_token_cache_ttl_minutes,
      :token_validation_stale_minutes,
      :agent_timeout_seconds,
      :max_execution_seconds,
      :default_agent_provider,
      :container_memory_gb,
      :max_concurrent_runs,
      :max_auto_pick_open_prs,
      :container_timeout_seconds,
      :default_branch,
      :default_project_active,
      :default_allowed_github_usernames_csv,
      :allowed_service_images_csv,
      :max_tokens_per_run,
      :issue_goal_timeout_seconds,
      :issue_goal_idle_timeout_seconds,
      :review_goal_idle_timeout_seconds,
      :git_clone_timeout_seconds,
      :git_push_timeout_seconds,
      :max_prompt_comments,
      :max_comment_length,
      :style_guide_max_raw_bytes,
      :style_guide_max_total_bytes,
      :style_guide_max_raw_prompt_bytes,
      :circuit_breaker_failure_threshold,
      :circuit_breaker_timeout_seconds,
      :retry_max_attempts,
      :retry_base_delay,
      :retry_max_delay,
      :max_issues_per_page,
      :max_prs_per_page,
      :fallback_enabled,
      :fallback_providers,
      :kb_embedding_provider,
      :kb_chat_provider,
      auto_pick_skip_labels: []
    )

    if raw_params.key?(:auto_pick_skip_labels)
      permitted[:auto_pick_skip_labels] = AutoPickSkipLabels.normalize(raw_params[:auto_pick_skip_labels])
    elsif raw_params.key?(:auto_pick_skip_labels_override) || raw_params.key?(:auto_pick_skip_labels_csv)
      permitted[:auto_pick_skip_labels] =
        if ActiveModel::Type::Boolean.new.cast(raw_params[:auto_pick_skip_labels_override])
          AutoPickSkipLabels.parse_csv(raw_params[:auto_pick_skip_labels_csv])
        end
    end

    %i[
      fallback_providers
      kb_embedding_fallback_providers
      kb_chat_fallback_providers
    ].each do |key|
      next unless raw_params.key?(key)

      permitted[key] = UserSetting.parse_provider_array_param(raw_params[key])
    end

    permitted
  end
end
