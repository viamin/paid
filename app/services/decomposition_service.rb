# frozen_string_literal: true

# Policy-aware decomposition service that resolves coordination policies before
# falling back to orchestration strategy defaults.
class DecompositionService
  POLICY_TYPE = "decomposition"
  POLICY_KEY = "feature_decomposition"
  STRATEGY_TYPE = "feature_orchestration"

  DEFAULT_POLICY = OrchestrationStrategies::Defaults
    .feature_orchestration
    .fetch("decomposition")
    .freeze

  def self.call(...)
    new(...).call
  end

  def initialize(title:, description:, sub_components:, project: nil, account: nil, policy_override: nil)
    @title = title.to_s
    @description = description.to_s
    @sub_components = Array(sub_components)
    @project = project
    @account = account || project&.account
    @policy_override = policy_override
  end

  def call
    policy = resolve_policy

    unless policy_enabled?(policy)
      return skip_result(reason: "decomposition_disabled_by_policy", policy:)
    end

    unless should_decompose?(policy)
      return skip_result(reason: "below_complexity_threshold", policy:)
    end

    plan_result = DecompositionPlan::Generate.call(
      title:,
      description:,
      sub_components:,
      max_tasks: policy["max_tasks"],
      layer_order: policy["layer_order"]
    )

    Result.new(
      tasks: plan_result.tasks,
      valid: plan_result.valid?,
      sorted_indices: plan_result.sorted_indices,
      errors: plan_result.errors,
      decomposed: plan_result.task_count > 1,
      policy_applied: policy,
      policy_source: policy["source"],
      skipped: false,
      skip_reason: nil
    )
  end

  private

  attr_reader :title, :description, :sub_components, :project, :account, :policy_override

  def resolve_policy
    return experiment_policy if policy_override.present?

    resolve_coordination_policy || resolve_strategy_policy
  rescue => e
    Rails.logger.warn(
      message: "coordination.decomposition_policy_resolution_failed",
      project_id: project&.id,
      account_id: account&.id,
      error_class: e.class.name,
      error_message: e.message
    )
    fallback_policy("fallback")
  end

  def experiment_policy
    normalize_policy(
      DEFAULT_POLICY.merge(extract_decomposition_config_from_hash(policy_override))
        .merge("source" => "experiment")
    )
  end

  def resolve_coordination_policy
    return unless coordination_policy&.current_version

    rules = extract_decomposition_config_from_hash(coordination_policy.current_version.rules)
    parameters = extract_decomposition_config_from_hash(coordination_policy.current_version.parameters)

    normalize_policy(
      DEFAULT_POLICY
        .merge(rules)
        .merge(parameters)
        .merge(
          "source" => "coordination_policy",
          "policy_key" => coordination_policy.policy_key,
          "coordination_policy_id" => coordination_policy.id,
          "coordination_policy_version_id" => coordination_policy.current_version.id,
          "coordination_policy_version" => coordination_policy.current_version.version
        )
    )
  end

  def resolve_strategy_policy
    strategy = OrchestrationStrategies::Resolve.call(
      strategy_type: STRATEGY_TYPE,
      account:
    )

    decomposition_config = extract_decomposition_config(strategy, ignore_default_nested_values: true)
    source = decomposition_config.any? ? STRATEGY_TYPE : "defaults"

    normalize_policy(
      DEFAULT_POLICY.merge(decomposition_config).merge("source" => source)
    )
  end

  def coordination_policy
    return unless account

    @coordination_policy ||= CoordinationPolicy
      .active
      .by_type(POLICY_TYPE)
      .where(account:, policy_key: POLICY_KEY)
      .where(project_id: policy_scope_ids)
      .includes(:current_version)
      .order(Arel.sql("CASE WHEN project_id IS NOT NULL THEN 0 ELSE 1 END"), id: :desc)
      .find { |candidate| candidate.current_version.present? }
  end

  def policy_scope_ids
    return [ nil ] unless project

    [ nil, project.id ]
  end

  def extract_decomposition_config(strategy, ignore_default_nested_values: false)
    return {} unless strategy

    extract_decomposition_config_from_hash(
      strategy.configuration,
      ignore_default_nested_values:
    )
  end

  def extract_decomposition_config_from_hash(config, ignore_default_nested_values: false)
    return {} unless config.is_a?(Hash)

    {}.tap do |result|
      decomposition = config.fetch("decomposition", {})
      if decomposition.is_a?(Hash)
        result["max_tasks"] = decomposition["max_tasks"] if include_nested_override?(
          decomposition,
          key: "max_tasks",
          default: DEFAULT_POLICY["max_tasks"],
          ignore_default_nested_values:
        )
        result["min_components_to_decompose"] = decomposition["min_components_to_decompose"] if include_nested_override?(
          decomposition,
          key: "min_components_to_decompose",
          default: DEFAULT_POLICY["min_components_to_decompose"],
          ignore_default_nested_values:
        )
        result["enabled"] = decomposition["enabled"] if include_nested_override?(
          decomposition,
          key: "enabled",
          default: DEFAULT_POLICY["enabled"],
          ignore_default_nested_values:
        )
        result["layer_order"] = decomposition["layer_order"] if include_nested_override?(
          decomposition,
          key: "layer_order",
          default: DEFAULT_POLICY["layer_order"],
          ignore_default_nested_values:
        )
      end

      result["max_tasks"] = config["max_tasks"] if config.key?("max_tasks")
      result["min_components_to_decompose"] = config["min_components_to_decompose"] if config.key?("min_components_to_decompose")
      result["enabled"] = config["decomposition_enabled"] if config.key?("decomposition_enabled")
      result["layer_order"] = config["layer_order"] if config.key?("layer_order")
    end.compact
  end

  def include_nested_override?(config, key:, default:, ignore_default_nested_values:)
    return false unless config.key?(key)
    return true unless ignore_default_nested_values

    config[key] != default
  end

  def policy_enabled?(policy)
    policy.fetch("enabled", true)
  end

  def should_decompose?(policy)
    threshold = policy.fetch("min_components_to_decompose", DEFAULT_POLICY["min_components_to_decompose"])
    sub_components.size >= threshold
  end

  def skip_result(reason:, policy:)
    Result.new(
      tasks: [].freeze,
      valid: true,
      sorted_indices: [].freeze,
      errors: [].freeze,
      decomposed: false,
      policy_applied: policy,
      policy_source: policy["source"],
      skipped: true,
      skip_reason: reason
    )
  end

  def fallback_policy(source)
    normalize_policy(
      DEFAULT_POLICY.merge(
        "source" => source,
        "policy_key" => POLICY_KEY,
        "coordination_policy_id" => nil,
        "coordination_policy_version_id" => nil,
        "coordination_policy_version" => nil
      )
    )
  end

  def normalize_policy(policy)
    {
      "max_tasks" => normalize_max_tasks(policy["max_tasks"]),
      "min_components_to_decompose" => normalize_min_components(policy["min_components_to_decompose"]),
      "enabled" => normalize_enabled(policy["enabled"]),
      "layer_order" => normalize_layer_order(policy["layer_order"]),
      "source" => policy["source"],
      "policy_key" => policy["policy_key"],
      "coordination_policy_id" => policy["coordination_policy_id"],
      "coordination_policy_version_id" => policy["coordination_policy_version_id"],
      "coordination_policy_version" => policy["coordination_policy_version"]
    }
  end

  def normalize_json_object(value)
    value.is_a?(Hash) ? value : {}
  end

  def normalize_max_tasks(value)
    Integer(value).clamp(1, DEFAULT_POLICY["max_tasks"])
  rescue ArgumentError, TypeError
    DEFAULT_POLICY["max_tasks"]
  end

  def normalize_min_components(value)
    [ Integer(value), 1 ].max
  rescue ArgumentError, TypeError
    DEFAULT_POLICY["min_components_to_decompose"]
  end

  def normalize_enabled(value)
    return value if value == true || value == false

    case value.to_s.strip.downcase
    when "true" then true
    when "false" then false
    else DEFAULT_POLICY["enabled"]
    end
  end

  def normalize_layer_order(value)
    requested_layers = Array(value).filter_map do |layer|
      normalized = layer.to_s
      normalized if DEFAULT_POLICY["layer_order"].include?(normalized)
    end

    (requested_layers + DEFAULT_POLICY["layer_order"]).uniq
  end

  class Result
    attr_reader :tasks, :sorted_indices, :errors, :policy_applied,
      :policy_source, :skip_reason

    def initialize(tasks:, valid:, sorted_indices:, errors:, decomposed:,
      policy_applied:, policy_source:, skipped:, skip_reason:)
      @tasks = tasks
      @valid = valid
      @sorted_indices = sorted_indices
      @errors = errors
      @decomposed = decomposed
      @policy_applied = policy_applied
      @policy_source = policy_source
      @skipped = skipped
      @skip_reason = skip_reason
    end

    def valid? = @valid
    def decomposed? = @decomposed
    def skipped? = @skipped
    def task_count = tasks.size
  end
end
