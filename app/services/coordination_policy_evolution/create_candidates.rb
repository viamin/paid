# frozen_string_literal: true

module CoordinationPolicyEvolution
  class CreateCandidates
    APPROVAL_STATE = {
      "required" => true,
      "status" => "pending_review",
      "auto_promote" => false
    }.freeze
    SUPPORTED_POLICY_TYPES = %w[decomposition recovery escalation].freeze

    def self.call(...)
      new(...).call
    end

    def initialize(policy_snapshot:, account:, mutations:)
      @policy_snapshot = policy_snapshot.deep_symbolize_keys
      @account = account
      @mutations = Array(mutations)

      validate_policy_type!
    end

    def call
      return [] if mutations.empty?

      ActiveRecord::Base.transaction do
        account.with_lock do
          policy = coordination_policy
          next_version = next_version_number

          mutations.map do |mutation|
            candidate = policy.coordination_policy_versions.create!(
              version: next_version,
              status: "draft",
              rules: candidate_rules(mutation),
              parameters: candidate_parameters(mutation),
              metadata: candidate_metadata(mutation),
              reasoning: mutation.reasoning,
              llm_prompt: policy_snapshot[:llm_prompt]
            )
            next_version += 1
            candidate
          end
        end
      end
    end

    private

    attr_reader :policy_snapshot, :account, :mutations

    def validate_policy_type!
      return if SUPPORTED_POLICY_TYPES.include?(policy_type)

      raise ArgumentError, "unsupported coordination policy type: #{policy_type.inspect}"
    end

    def coordination_policy
      @coordination_policy ||= begin
        account.coordination_policies.find_by(id: policy_snapshot[:id]) ||
          account.coordination_policies.find_or_create_by!(
            project_id: policy_snapshot[:project_id],
            policy_type: policy_type,
            policy_key: policy_key
          ) do |policy|
            policy.name = policy_name
            policy.description = policy_snapshot[:description]
            policy.status = "draft"
            policy.context_selector = policy_snapshot[:context_selector] || {}
            policy.metadata = {
              "created_by" => self.class.name,
              "bootstrap_source" => policy_snapshot[:source]
            }.compact
          end
      end
    end

    def policy_type
      policy_snapshot.fetch(:policy_type)
    end

    def policy_key
      policy_snapshot.fetch(:policy_key)
    end

    def policy_name
      policy_snapshot.fetch(:name)
    end

    def next_version_number
      current_max = coordination_policy.coordination_policy_versions.maximum(:version).to_i
      [ current_max + 1, 1 ].max
    end

    def candidate_rules(mutation)
      configuration = mutation.configuration.deep_stringify_keys

      case policy_type
      when "decomposition"
        decomposition = extract_decomposition_config(configuration)

        {
          "enabled" => decomposition["enabled"],
          "min_components_to_decompose" => decomposition["min_components_to_decompose"]
        }.compact
      when "recovery"
        recovery = extract_recovery_config(configuration)

        {
          "failure_actions" => recovery["actions"]
        }.compact
      when "escalation"
        escalation = extract_escalation_config(configuration)

        {
          "explicit_triggers" => escalation["explicit_triggers"],
          "auto_resolve_trigger_types" => escalation["auto_resolve_trigger_types"]
        }.compact
      else
        {}
      end
    end

    def candidate_parameters(mutation)
      configuration = mutation.configuration.deep_stringify_keys

      case policy_type
      when "decomposition"
        decomposition = extract_decomposition_config(configuration)

        {
          "max_tasks" => decomposition["max_tasks"],
          "layer_order" => decomposition["layer_order"]
        }.compact
      when "recovery"
        recovery = extract_recovery_config(configuration)

        {
          "default_action" => recovery["default_action"]
        }.compact
      when "escalation"
        escalation = extract_escalation_config(configuration)

        {
          "human_value_threshold" => escalation["human_value_threshold"],
          "weights" => escalation["weights"],
          "interruption_cost" => escalation["interruption_cost"]
        }.compact
      else
        {}
      end
    end

    def candidate_metadata(mutation)
      {
        "evolution" => {
          "source_policy_id" => policy_snapshot[:id],
          "source_policy_version_id" => policy_snapshot[:version_id],
          "source_version" => policy_snapshot[:version],
          "generated_at" => Time.current.iso8601,
          "mutation_strategy" => mutation.strategy,
          "reasoning" => mutation.reasoning,
          "expected_improvement" => mutation.expected_improvement,
          "diff" => mutation.diff,
          "provenance" => mutation.provenance,
          "approval" => APPROVAL_STATE
        }
      }
    end

    def extract_decomposition_config(configuration)
      decomposition = configuration.fetch("decomposition", {})

      {}.tap do |config|
        if decomposition.is_a?(Hash)
          config["enabled"] = decomposition["enabled"] if decomposition.key?("enabled")
          config["min_components_to_decompose"] = decomposition["min_components_to_decompose"] if decomposition.key?("min_components_to_decompose")
          config["max_tasks"] = decomposition["max_tasks"] if decomposition.key?("max_tasks")
          config["layer_order"] = decomposition["layer_order"] if decomposition.key?("layer_order")
        end

        config["enabled"] = configuration["enabled"] if configuration.key?("enabled")
        config["enabled"] = configuration["decomposition_enabled"] if configuration.key?("decomposition_enabled")
        config["min_components_to_decompose"] = configuration["min_components_to_decompose"] if configuration.key?("min_components_to_decompose")
        config["max_tasks"] = configuration["max_tasks"] if configuration.key?("max_tasks")
        config["layer_order"] = configuration["layer_order"] if configuration.key?("layer_order")
      end.compact
    end

    def extract_recovery_config(configuration)
      recovery = configuration.fetch("recovery", {})
      actions = if recovery.is_a?(Hash)
        recovery["actions"] || recovery["failure_actions"]
      end
      actions ||= configuration["actions"] || configuration["failure_actions"]

      {}.tap do |config|
        config["actions"] = actions if actions.is_a?(Hash)
        config["default_action"] = recovery["default_action"] if recovery.is_a?(Hash) && recovery.key?("default_action")
        config["default_action"] = configuration["default_action"] if configuration.key?("default_action")
      end.compact
    end

    def extract_escalation_config(configuration)
      escalation = configuration.fetch("escalation", {})

      {}.tap do |config|
        %w[
          human_value_threshold
          explicit_triggers
          auto_resolve_trigger_types
          weights
          interruption_cost
        ].each do |key|
          config[key] = escalation[key] if escalation.is_a?(Hash) && escalation.key?(key)
          config[key] = configuration[key] if configuration.key?(key)
        end
      end.compact
    end
  end
end
