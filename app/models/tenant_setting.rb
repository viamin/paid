# frozen_string_literal: true

class TenantSetting < ApplicationRecord
  PG_INT_MAX = 2_147_483_647
  BUDGET_TYPES = CostBudget::BUDGET_TYPES
  DEFAULT_PROVIDER_PREFERENCES = {
    "model_preferences" => {},
    "api_key_ids" => {}
  }.freeze
  DEFAULT_BUDGET_TEMPLATE = {
    "enabled" => false,
    "limit_cents" => nil,
    "alert_threshold_percent" => 80,
    "enforcement_mode" => "alert",
    "grace_buffer_percent" => 0
  }.freeze
  DEFAULT_BUDGETS = BUDGET_TYPES.index_with { DEFAULT_BUDGET_TEMPLATE.deep_dup }.freeze
  DEFAULT_GUARDRAILS = {
    "max_concurrent_runs" => 10,
    "max_tokens_per_run" => 10_000_000,
    "max_monthly_cost_cents" => nil
  }.freeze
  DEFAULT_QUALITY_THRESHOLDS = Project::DEFAULT_QUALITY_GATE_SETTINGS.freeze
  DEFAULT_AGENT_SETTINGS = {
    "default_goal" => "create_pr",
    "auto_continue" => true
  }.freeze

  belongs_to :account

  before_validation :normalize_configuration_namespaces

  validates :max_concurrent_runs,
    numericality: { only_integer: true, greater_than_or_equal_to: 1, less_than_or_equal_to: 100 }
  validates :max_projects,
    numericality: { only_integer: true, greater_than_or_equal_to: 1, less_than_or_equal_to: PG_INT_MAX }
  validates :max_users,
    numericality: { only_integer: true, greater_than_or_equal_to: 1, less_than_or_equal_to: PG_INT_MAX }
  validates :max_tokens_per_run,
    numericality: { only_integer: true, greater_than_or_equal_to: 1, less_than_or_equal_to: PG_INT_MAX }
  validates :max_monthly_cost_cents,
    numericality: { only_integer: true, greater_than_or_equal_to: 0, less_than_or_equal_to: PG_INT_MAX },
    allow_nil: true
  validate :validate_features_is_hash
  validate :validate_configuration_namespaces
  validate :validate_default_budgets

  def configuration
    {
      "provider_preferences" => effective_provider_preferences,
      "default_budgets" => effective_default_budgets,
      "guardrails" => effective_guardrails,
      "quality_thresholds" => effective_quality_thresholds,
      "agent_settings" => effective_agent_settings,
      "features" => features
    }
  end

  def effective_provider_preferences
    merge_defaults(DEFAULT_PROVIDER_PREFERENCES, provider_preferences)
  end

  def effective_default_budgets
    merge_defaults(DEFAULT_BUDGETS, default_budgets)
  end

  def effective_guardrails
    DEFAULT_GUARDRAILS.merge(
      "max_concurrent_runs" => max_concurrent_runs,
      "max_tokens_per_run" => max_tokens_per_run,
      "max_monthly_cost_cents" => max_monthly_cost_cents
    ).deep_merge(guardrails.is_a?(Hash) ? guardrails.deep_stringify_keys : {})
  end

  def effective_quality_thresholds
    merge_defaults(DEFAULT_QUALITY_THRESHOLDS, quality_thresholds)
  end

  def effective_agent_settings
    merge_defaults(DEFAULT_AGENT_SETTINGS, agent_settings)
  end

  def default_cost_budget_attributes
    effective_default_budgets.filter_map do |budget_type, settings|
      next unless settings["enabled"]
      next if settings["limit_cents"].blank?

      settings.slice("limit_cents", "alert_threshold_percent", "enforcement_mode", "grace_buffer_percent")
        .merge("budget_type" => budget_type)
    end
  end

  def provider_api_key_for(api_service_type)
    key_id = effective_provider_preferences.dig("api_key_ids", api_service_type.to_s)
    return nil if key_id.blank?

    account.provider_api_keys.find_by(id: key_id)
  end

  def model_preference_for(provider_key)
    effective_provider_preferences.dig("model_preferences", provider_key.to_s).presence
  end

  def auto_continue?
    effective_agent_settings["auto_continue"] == true
  end

  def default_goal
    effective_agent_settings["default_goal"].presence || DEFAULT_AGENT_SETTINGS.fetch("default_goal")
  end

  def cap_max_concurrent_runs(limit)
    [ limit, max_concurrent_runs ].compact.min
  end

  def cap_max_tokens_per_run(limit)
    [ limit, max_tokens_per_run ].compact.min
  end

  private

  def normalize_configuration_namespaces
    self.provider_preferences = normalize_hash(provider_preferences)
    self.default_budgets = normalize_budget_hash(default_budgets)
    self.guardrails = normalize_integer_hash(guardrails, %w[max_concurrent_runs max_tokens_per_run max_monthly_cost_cents])
    self.quality_thresholds = normalize_quality_thresholds(quality_thresholds)
    self.agent_settings = normalize_agent_settings(agent_settings)
    self.features = normalize_hash(features)
    apply_guardrail_columns
  end

  def validate_features_is_hash
    return if features.is_a?(Hash)

    errors.add(:features, "must be a JSON object")
  end

  def validate_configuration_namespaces
    %i[provider_preferences default_budgets guardrails quality_thresholds agent_settings].each do |attribute|
      errors.add(attribute, "must be a JSON object") unless public_send(attribute).is_a?(Hash)
    end
  end

  def validate_default_budgets
    return unless default_budgets.is_a?(Hash)

    default_budgets.each do |budget_type, settings|
      validate_budget_type(budget_type)
      validate_budget_settings(budget_type, settings) if settings.is_a?(Hash)
    end
  end

  def validate_budget_type(budget_type)
    return if BUDGET_TYPES.include?(budget_type.to_s)

    errors.add(:default_budgets, "contains unsupported budget type: #{budget_type}")
  end

  def validate_budget_settings(budget_type, settings)
    errors.add(:default_budgets, "#{budget_type} limit_cents must be positive") if settings["enabled"] && settings["limit_cents"].to_i <= 0
    return if CostBudget::ENFORCEMENT_MODES.include?(settings["enforcement_mode"])

    errors.add(:default_budgets, "#{budget_type} enforcement_mode is unsupported")
  end

  def normalize_budget_hash(value)
    normalized_value = normalize_hash(value)
    return normalized_value unless normalized_value.is_a?(Hash)

    normalized_value.each_with_object({}) do |(budget_type, settings), result|
      next unless settings.is_a?(Hash)

      result[budget_type.to_s] = normalize_hash(settings).tap do |normalized|
        normalized["enabled"] = ActiveModel::Type::Boolean.new.cast(normalized["enabled"])
        %w[limit_cents alert_threshold_percent grace_buffer_percent].each do |key|
          normalized[key] = normalized[key].present? ? normalized[key].to_i : nil
        end
      end
    end
  end

  def normalize_hash(value)
    return {} if value.nil?
    return value.deep_stringify_keys if value.respond_to?(:deep_stringify_keys)

    value
  end

  def normalize_integer_hash(value, keys)
    normalize_hash(value).tap do |normalized|
      next unless normalized.is_a?(Hash)

      keys.each do |key|
        normalized[key] = normalized[key].present? ? normalized[key].to_i : nil if normalized.key?(key)
      end
    end
  end

  def normalize_quality_thresholds(value)
    normalize_hash(value).tap do |normalized|
      next unless normalized.is_a?(Hash)

      normalized["enabled"] = ActiveModel::Type::Boolean.new.cast(normalized["enabled"]) if normalized.key?("enabled")
      %w[composite_score_threshold].each do |key|
        normalized[key] = normalized[key].present? ? normalized[key].to_f : nil if normalized.key?(key)
      end
      %w[min_recent_runs lookback_window_hours].each do |key|
        normalized[key] = normalized[key].present? ? normalized[key].to_i : nil if normalized.key?(key)
      end
    end
  end

  def normalize_agent_settings(value)
    normalize_hash(value).tap do |normalized|
      next unless normalized.is_a?(Hash)

      normalized["auto_continue"] = ActiveModel::Type::Boolean.new.cast(normalized["auto_continue"]) if normalized.key?("auto_continue")
    end
  end

  def apply_guardrail_columns
    return unless guardrails.is_a?(Hash)

    self.max_concurrent_runs = guardrails["max_concurrent_runs"] if guardrails.key?("max_concurrent_runs")
    self.max_tokens_per_run = guardrails["max_tokens_per_run"] if guardrails.key?("max_tokens_per_run")
    self.max_monthly_cost_cents = guardrails["max_monthly_cost_cents"] if guardrails.key?("max_monthly_cost_cents")
  end

  def merge_defaults(defaults, stored)
    defaults.deep_dup.deep_merge(stored.is_a?(Hash) ? stored.deep_stringify_keys : {})
  end
end
