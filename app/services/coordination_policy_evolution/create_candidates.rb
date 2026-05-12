# frozen_string_literal: true

module CoordinationPolicyEvolution
  class CreateCandidates
    APPROVAL_STATE = {
      "required" => true,
      "status" => "pending_review",
      "auto_promote" => false
    }.freeze

    def self.call(...)
      new(...).call
    end

    def initialize(policy_snapshot:, account:, mutations:)
      @policy_snapshot = policy_snapshot.deep_symbolize_keys
      @account = account
      @mutations = Array(mutations)
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
      decomposition = mutation.configuration.deep_stringify_keys.fetch("decomposition", {})

      {
        "enabled" => decomposition["enabled"],
        "min_components_to_decompose" => decomposition["min_components_to_decompose"]
      }.compact
    end

    def candidate_parameters(mutation)
      decomposition = mutation.configuration.deep_stringify_keys.fetch("decomposition", {})

      {
        "max_tasks" => decomposition["max_tasks"],
        "layer_order" => decomposition["layer_order"]
      }.compact
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
  end
end
