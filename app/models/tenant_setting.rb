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
  DEFAULT_CHAT_SETTINGS = {
    "chat_session_token_limit" => 100_000,
    "chat_monthly_token_limit" => nil
  }.freeze
  DEFAULT_QUALITY_THRESHOLDS = Project::DEFAULT_QUALITY_GATE_SETTINGS.freeze
  DEFAULT_AGENT_SETTINGS = {
    "default_goal" => "create_pr",
    "auto_continue" => true
  }.freeze
  DEFAULT_WORKER_SETTINGS = {
    "temporal_workflow_slots" => 20,
    "temporal_activity_slots" => 4,
    "temporal_poll_workflow_slots" => 20,
    "temporal_poll_activity_slots" => 10,
    "good_job_max_threads" => 11,
    "good_job_queues" => "default:3;maintenance:2;metrics:2;knowledge:3;low_priority:1"
  }.freeze
  WORKER_SETTING_INTEGER_KEYS = %w[
    temporal_workflow_slots temporal_activity_slots
    temporal_poll_workflow_slots temporal_poll_activity_slots
    good_job_max_threads
  ].freeze
  PLAN_DEFAULTS = {
    "trial" => { max_concurrent_runs: 2, max_projects: 3, max_users: 5, max_tokens_per_run: 5_000_000 },
    "free" => { max_concurrent_runs: 3, max_projects: 5, max_users: 10, max_tokens_per_run: 5_000_000 },
    "professional" => { max_concurrent_runs: 10, max_projects: 50, max_users: 25, max_tokens_per_run: 10_000_000 },
    "enterprise" => { max_concurrent_runs: 100, max_projects: 1000, max_users: 500, max_tokens_per_run: PG_INT_MAX }
  }.freeze
  REPO_NAME_FORMAT = /\A[a-zA-Z0-9_.-]+\/[a-zA-Z0-9_.-]+\z/

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
  validate :validate_agent_settings
  validate :validate_worker_settings
  validates :self_repo_full_name,
    format: { with: REPO_NAME_FORMAT, message: "must be in owner/repo format" },
    allow_nil: true,
    if: -> { self_repo_full_name.present? }

  def configuration
    {
      "provider_preferences" => effective_provider_preferences,
      "default_budgets" => effective_default_budgets,
      "guardrails" => effective_guardrails,
      "quality_thresholds" => effective_quality_thresholds,
      "agent_settings" => effective_agent_settings,
      "worker_settings" => effective_worker_settings,
      "chat_settings" => effective_chat_settings,
      "self_repo_full_name" => self_repo_full_name,
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
    goal = effective_agent_settings["default_goal"].presence
    return goal if AgentRun::GOALS.include?(goal)

    DEFAULT_AGENT_SETTINGS.fetch("default_goal")
  end

  def effective_chat_settings
    merge_defaults(DEFAULT_CHAT_SETTINGS, features.fetch("chat_settings", {}))
  end

  def chat_session_token_limit
    effective_chat_settings["chat_session_token_limit"]
  end

  def chat_monthly_token_limit
    effective_chat_settings["chat_monthly_token_limit"]
  end

  def cap_max_concurrent_runs(limit)
    [ limit, max_concurrent_runs ].compact.min
  end

  def cap_max_tokens_per_run(limit)
    [ limit, max_tokens_per_run ].compact.min
  end

  def effective_worker_settings
    DEFAULT_WORKER_SETTINGS.deep_dup.merge(
      worker_settings.is_a?(Hash) ? worker_settings.deep_stringify_keys : {}
    )
  end

  def worker_setting(key)
    effective_worker_settings[key.to_s]
  end

  def self.defaults_for_plan(plan)
    PLAN_DEFAULTS.fetch(plan.to_s, PLAN_DEFAULTS["trial"])
  end

  def self.resolve_worker_setting(key, env_key:, env:, default:)
    db_val = read_worker_setting_from_db(key)
    return db_val if db_val.present?
    return Integer(env.fetch(env_key, default.to_s)) if WORKER_SETTING_INTEGER_KEYS.include?(key.to_s)

    env.fetch(env_key, default.to_s)
  rescue ArgumentError
    default
  end

  def self.read_worker_setting_from_db(key)
    return nil unless table_exists?

    setting = (Current.account || Account.order(:id).first)&.tenant_setting
    return nil unless setting

    value = setting.worker_settings&.dig(key.to_s)
    return nil if value.nil?

    WORKER_SETTING_INTEGER_KEYS.include?(key.to_s) ? value.to_i : value.to_s
  rescue ActiveRecord::NoDatabaseError, PG::ConnectionBad
    nil
  end

  private_class_method :read_worker_setting_from_db

  private

  def normalize_configuration_namespaces
    self.provider_preferences = normalize_hash(provider_preferences)
    self.default_budgets = normalize_budget_hash(default_budgets)
    self.guardrails = normalize_integer_hash(guardrails, %w[max_concurrent_runs max_tokens_per_run max_monthly_cost_cents])
    self.quality_thresholds = normalize_quality_thresholds(quality_thresholds)
    self.agent_settings = normalize_agent_settings(agent_settings)
    self.worker_settings = normalize_worker_settings(worker_settings)
    self.features = normalize_hash(features)
    apply_guardrail_columns
  end

  def validate_features_is_hash
    return if features.is_a?(Hash)

    errors.add(:features, "must be a JSON object")
  end

  def validate_configuration_namespaces
    %i[provider_preferences default_budgets guardrails quality_thresholds agent_settings worker_settings].each do |attribute|
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

  def validate_agent_settings
    return unless agent_settings.is_a?(Hash)

    goal = agent_settings["default_goal"].presence
    return if goal.blank? || AgentRun::GOALS.include?(goal)

    errors.add(:agent_settings, "default_goal is unsupported")
  end

  def validate_worker_settings
    return unless worker_settings.is_a?(Hash)

    worker_settings.each do |key, value|
      if WORKER_SETTING_INTEGER_KEYS.include?(key.to_s)
        unless value.is_a?(Integer) && value >= 1 && value <= 100
          errors.add(:worker_settings, "#{key} must be an integer between 1 and 100")
        end
      elsif key.to_s == "good_job_queues"
        next if value.is_a?(String) && value.match?(/\A([a-z_]+:\d+)(;[a-z_]+:\d+)*\z/)
        errors.add(:worker_settings, "good_job_queues must match format 'name:count;name:count'")
      end
    end
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

  def normalize_worker_settings(value)
    normalize_hash(value).tap do |normalized|
      next unless normalized.is_a?(Hash)

      WORKER_SETTING_INTEGER_KEYS.each do |key|
        normalized[key] = normalized[key].present? ? normalized[key].to_i : nil if normalized.key?(key)
      end
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
