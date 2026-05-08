# frozen_string_literal: true

module Coordination
  # Policy-based decomposition service that consumes orchestration strategies
  # to drive task decomposition decisions.
  #
  # Wraps the existing DecompositionPlan::Generate pipeline with policy rules
  # resolved from the feature_orchestration strategy, allowing account-level
  # customization of decomposition behavior (max tasks, complexity thresholds,
  # layer ordering, etc.) while preserving safe fallbacks.
  #
  # @example Basic usage
  #   result = Coordination::DecompositionService.call(
  #     title: "User notification system",
  #     description: issue.body,
  #     sub_components: scope_result.sub_components,
  #     account: project.account
  #   )
  #   result.tasks        # => [{ title: "...", deps: [], scope: "model" }, ...]
  #   result.decomposed?  # => true
  #   result.policy_source # => "feature_orchestration"
  class DecompositionService
    STRATEGY_TYPE = "feature_orchestration"

    # Default policy values used when no strategy is configured or when
    # the strategy configuration is missing decomposition-specific keys.
    DEFAULT_POLICY = {
      "max_tasks" => 20,
      "min_components_to_decompose" => 2,
      "enabled" => true,
      "layer_order" => %w[model service controller view]
    }.freeze

    def self.call(...)
      new(...).call
    end

    def initialize(title:, description:, sub_components:, account: nil)
      @title = title.to_s
      @description = description.to_s
      @sub_components = Array(sub_components)
      @account = account
    end

    def call
      policy = resolve_policy

      unless policy_enabled?(policy)
        return skip_result(reason: "decomposition_disabled_by_policy", policy: policy)
      end

      unless should_decompose?(policy)
        return skip_result(reason: "below_complexity_threshold", policy: policy)
      end

      plan_result = DecompositionPlan::Generate.call(
        title: title,
        description: description,
        sub_components: sub_components,
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

    attr_reader :title, :description, :sub_components, :account

    def resolve_policy
      strategy = OrchestrationStrategies::Resolve.call(
        strategy_type: STRATEGY_TYPE,
        account: account
      )

      decomposition_config = extract_decomposition_config(strategy)
      source = strategy&.persisted? ? "database" : "defaults"

      normalize_policy(DEFAULT_POLICY.merge(decomposition_config).merge("source" => source))
    rescue => e
      Rails.logger.warn(
        message: "coordination.decomposition_policy_resolution_failed",
        error_class: e.class.name,
        error: e.message
      )
      normalize_policy(DEFAULT_POLICY.merge("source" => "fallback"))
    end

    def extract_decomposition_config(strategy)
      return {} unless strategy

      config = strategy.configuration
      return {} unless config.is_a?(Hash)

      # Extract decomposition-relevant keys from the feature_orchestration config.
      # Strategy may contain a nested "decomposition" key with overrides, or
      # top-level keys that map to decomposition parameters.
      decomposition = config.fetch("decomposition", {})
      return decomposition if decomposition.is_a?(Hash) && decomposition.any?

      # Fall back to inferring from top-level feature_orchestration config
      {}.tap do |result|
        result["max_tasks"] = config["max_tasks"] if config.key?("max_tasks")
        result["min_components_to_decompose"] = config["min_components_to_decompose"] if config.key?("min_components_to_decompose")
        result["enabled"] = config["decomposition_enabled"] if config.key?("decomposition_enabled")
        result["layer_order"] = config["layer_order"] if config.key?("layer_order")
      end.compact
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

    def normalize_policy(policy)
      {
        "max_tasks" => normalize_max_tasks(policy["max_tasks"]),
        "min_components_to_decompose" => normalize_min_components(policy["min_components_to_decompose"]),
        "enabled" => normalize_enabled(policy["enabled"]),
        "layer_order" => normalize_layer_order(policy["layer_order"]),
        "source" => policy["source"]
      }
    end

    def normalize_max_tasks(value)
      Integer(value).clamp(1, DEFAULT_POLICY["max_tasks"])
    rescue ArgumentError, TypeError
      DEFAULT_POLICY["max_tasks"]
    end

    def normalize_min_components(value)
      Integer(value).clamp(1, DEFAULT_POLICY["max_tasks"])
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
end
