# frozen_string_literal: true

class TenantConfigurationsController < ApplicationController
  before_action :set_tenant_setting

  def edit
    authorize current_account, :update?
    load_form_options
  end

  def update
    authorize current_account, :update?

    ActiveRecord::Base.transaction do
      @tenant_setting.update!(tenant_setting_params)
      update_feature_flag_rollouts! if feature_flag_rollout_params.present?

      if @tenant_setting.saved_changes.except("updated_at").any? ||
          (feature_flag_rollout_params.present? && changed_feature_flag_rollouts.any?)
        Accounts::RecordActivity.call(
          account: current_account,
          actor: current_user,
          action: "tenant_configuration.updated",
          subject: @tenant_setting,
          metadata: { changed_fields: @tenant_setting.saved_changes.except("updated_at").keys }
        )
      end
    end

    redirect_to edit_tenant_configuration_path, notice: "Tenant configuration saved successfully."
  rescue ActiveRecord::RecordInvalid, FeatureFlags::InvalidPercentageError => e
    @tenant_setting.errors.add(:base, e.message) if e.is_a?(FeatureFlags::InvalidPercentageError)
    load_form_options
    render :edit, status: :unprocessable_content
  end

  private

  def set_tenant_setting
    @tenant_setting = current_account.tenant_setting!
  end

  def load_form_options
    @provider_api_keys = current_account.provider_api_keys.includes(:user).order(:api_service_type, :name)
    @feature_flags = FeatureFlags.definitions
    @feature_flag_rollouts = @feature_flags.index_with do |definition|
      FeatureFlags.rollout_status(definition.name)
    end
  end

  def update_feature_flag_rollouts!
    changed = changed_feature_flag_rollouts
    return if changed.empty?

    # Flipper percentage gates are global (not tenant-scoped), so require
    # the stricter owner-only manage_feature_flags? policy to prevent
    # cross-tenant privilege escalation in multi-tenant deployments.
    authorize current_account, :manage_feature_flags?

    changed.each do |flag_name, rollout|
      FeatureFlags.enable_percentage_of_actors(flag_name, rollout["percentage_of_actors"])
      FeatureFlags.enable_percentage_of_time(flag_name, rollout["percentage_of_time"])
    end
  end

  def changed_feature_flag_rollouts
    originals = feature_flag_rollout_original_params
    feature_flag_rollout_params.select do |flag_name, rollout|
      original = originals.fetch(flag_name, {})
      normalize_pct(rollout["percentage_of_actors"]) != normalize_pct(original["percentage_of_actors"]) ||
        normalize_pct(rollout["percentage_of_time"]) != normalize_pct(original["percentage_of_time"])
    end
  end

  def normalize_pct(value)
    value.to_s.strip == "" ? 0 : Integer(value, exception: false) || -1
  end

  def feature_flag_rollout_params
    params.fetch(:feature_flag_rollouts) { ActionController::Parameters.new }.permit(
      FeatureFlags::DEFINITIONS.keys.index_with { %i[percentage_of_actors percentage_of_time] }
    ).to_h
  end

  def feature_flag_rollout_original_params
    params.fetch(:feature_flag_rollout_originals) { ActionController::Parameters.new }.permit(
      FeatureFlags::DEFINITIONS.keys.index_with { %i[percentage_of_actors percentage_of_time] }
    ).to_h
  end

  def tenant_setting_params
    raw_params = params.require(:tenant_setting)
    attrs = raw_params.permit(
      :max_concurrent_runs, :max_projects, :max_users, :max_tokens_per_run, :max_monthly_cost_cents,
      :self_repo_full_name,
      allowed_runner_keys: [],
      auto_pick_skip_labels: [],
      runner_preferences: [
        api_key_ids: RunnerSupport.api_service_types.keys,
        model_preferences: RunnerSupport.supported_runner_keys
      ],
      default_budgets: budget_params,
      guardrails: %i[max_concurrent_runs max_tokens_per_run max_monthly_cost_cents],
      quality_thresholds: [
        :enabled, :composite_score_threshold, :min_recent_runs, :lookback_window_hours,
        { metric_thresholds: {} }
      ],
      agent_settings: %i[default_goal auto_continue marketplace_auto_attach_required],
      worker_settings: %i[
        temporal_workflow_slots temporal_activity_slots
        temporal_poll_workflow_slots temporal_poll_activity_slots
        good_job_max_threads good_job_queues
      ],
      features: FeatureFlags::DEFINITIONS.keys
    ).to_h

    if raw_params.key?(:auto_pick_skip_labels)
      attrs["auto_pick_skip_labels"] = AutoPickSkipLabels.normalize(raw_params[:auto_pick_skip_labels])
    elsif raw_params.key?(:auto_pick_skip_labels_override) || raw_params.key?(:auto_pick_skip_labels_csv)
      attrs["auto_pick_skip_labels"] =
        if ActiveModel::Type::Boolean.new.cast(raw_params[:auto_pick_skip_labels_override])
          AutoPickSkipLabels.parse_csv(raw_params[:auto_pick_skip_labels_csv])
        end
    end

    attrs["features"] ||= {}
    FeatureFlags::DEFINITIONS.each_key do |flag_name|
      attrs["features"][flag_name.to_s] = ActiveModel::Type::Boolean.new.cast(attrs["features"][flag_name.to_s])
    end
    attrs
  end

  def budget_params
    CostBudget::BUDGET_TYPES.index_with do
      %i[enabled limit_cents alert_threshold_percent enforcement_mode grace_buffer_percent]
    end
  end
end
