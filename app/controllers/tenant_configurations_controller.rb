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
    feature_flag_rollout_params.select do |flag_name, rollout|
      current = FeatureFlags.rollout_status(flag_name)
      normalize_pct(rollout["percentage_of_actors"]) != current[:percentage_of_actors] ||
        normalize_pct(rollout["percentage_of_time"]) != current[:percentage_of_time]
    end
  end

  def normalize_pct(value)
    value.to_s.strip == "" ? 0 : Integer(value)
  end

  def feature_flag_rollout_params
    params.fetch(:feature_flag_rollouts, ActionController::Parameters.new).permit(
      FeatureFlags::DEFINITIONS.keys.index_with { %i[percentage_of_actors percentage_of_time] }
    ).to_h
  end

  def tenant_setting_params
    attrs = params.require(:tenant_setting).permit(
      :max_concurrent_runs, :max_projects, :max_users, :max_tokens_per_run, :max_monthly_cost_cents,
      allowed_provider_keys: [],
      provider_preferences: [
        api_key_ids: ProviderSupport.api_service_types.keys,
        model_preferences: ProviderSupport.supported_provider_keys
      ],
      default_budgets: budget_params,
      guardrails: %i[max_concurrent_runs max_tokens_per_run max_monthly_cost_cents],
      quality_thresholds: [
        :enabled, :composite_score_threshold, :min_recent_runs, :lookback_window_hours,
        { metric_thresholds: {} }
      ],
      agent_settings: %i[default_goal auto_continue],
      features: FeatureFlags::DEFINITIONS.keys
    ).to_h
    attrs["features"] ||= {}
    FeatureFlags::DEFINITIONS.keys.each do |flag_name|
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
