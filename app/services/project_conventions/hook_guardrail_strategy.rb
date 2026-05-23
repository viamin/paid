# frozen_string_literal: true

module ProjectConventions
  class HookGuardrailStrategy
    DEFAULT_ALLOWED_TYPES = %w[feat fix docs style refactor perf test build ci chore revert].freeze

    def self.recommendation_for(profile:)
      new(profile:).recommendation
    end

    def self.from_recommendation(recommendation)
      new(recommendation_evidence: recommendation.evidence).strategy
    end

    def initialize(profile: nil, recommendation_evidence: nil)
      @profile = profile
      @raw_recommendation_evidence = recommendation_evidence || {}
    end

    def recommendation
      return unless conventional_commits_required?

      case strategy.fetch("manager_type")
      when "lefthook", "husky", "githooks"
        {
          convention_key: "hook_manager",
          action_type: "open_pr",
          title: "Install repo-managed commit-msg guardrail",
          description: open_pr_description,
          evidence: serialized_recommendation_evidence,
          generated_at: Time.current
        }
      when "none"
        {
          convention_key: "hook_manager",
          action_type: "manual_review",
          title: "Choose a repo-managed hook strategy",
          description: manual_review_description,
          evidence: serialized_recommendation_evidence,
          generated_at: Time.current
        }
      end
    end

    def strategy
      @strategy ||= begin
        persisted = recommendation_strategy
        persisted.present? ? persisted : detected_strategy
      end
    end

    private

    attr_reader :profile, :raw_recommendation_evidence

    def recommendation_strategy
      value = raw_recommendation_evidence["strategy"]
      value.deep_stringify_keys if value.is_a?(Hash)
    end

    def detected_strategy
      manager_type = hook_manager_value["type"].presence || "none"
      manager_path = hook_manager_value["path"].presence
      {
        "manager_type" => manager_type,
        "manager_path" => manager_path,
        "validator_path" => ".paid/hooks/validate-commit-msg",
        "hook_path" => hook_path_for(manager_type, manager_path),
        "allowed_types" => allowed_types,
        "commit_style" => commit_style_value,
        "commit_style_paths" => commit_style_paths
      }.compact
    end

    def serialized_recommendation_evidence
      {
        "confidence" => strategy_confidence,
        "detected_value" => hook_manager_value.presence || { "type" => "none" },
        "hook_manager" => {
          "value" => hook_manager_value,
          "paths" => hook_manager_paths
        },
        "commit_style" => {
          "value" => commit_style_value,
          "paths" => commit_style_paths
        },
        "strategy" => strategy
      }
    end

    def conventional_commits_required?
      commit_style_value["type"] == "conventional_commits" &&
        commit_style_value["required"] == true &&
        commit_style_confidence >= 0.5
    end

    def open_pr_description
      allowed = allowed_types.join(", ")
      detected = manager_label
      commit_signal = commit_style_paths.presence&.join(", ") || "detected project conventions"

      "Detected #{detected} hooks and conventional commits from #{commit_signal}. " \
        "Open a PR that installs a repo-managed `commit-msg` guardrail with allowed types: #{allowed}."
    end

    def manual_review_description
      commit_signal = commit_style_paths.presence&.join(", ") || "detected project conventions"

      "Conventional commits were detected from #{commit_signal}, but no repo-managed hook system was found. " \
        "Paid will not guess between Husky, lefthook, or a versioned `.githooks` setup. Choose one of those " \
        "repo-owned strategies first, then rerun setup to install a durable `commit-msg` guardrail."
    end

    def hook_path_for(manager_type, manager_path)
      case manager_type
      when "husky"
        File.join(manager_path || ".husky", "commit-msg")
      when "githooks"
        File.join(manager_path || ".githooks", "commit-msg")
      when "lefthook"
        manager_path || "lefthook.yml"
      end
    end

    def allowed_types
      Array(commit_style_value["allowed_types"]).filter_map(&:presence).presence || DEFAULT_ALLOWED_TYPES
    end

    def commit_style_value
      @commit_style_value ||= profile_entry("commit_style").fetch(:value, {}).deep_stringify_keys
    end

    def hook_manager_value
      @hook_manager_value ||= profile_entry("hook_manager").fetch(:detected_value, {}).deep_stringify_keys
    end

    def hook_manager_paths
      Array(profile_entry("hook_manager").dig(:evidence, "paths")).filter_map(&:presence)
    end

    def commit_style_paths
      Array(profile_entry("commit_style").dig(:evidence, "paths")).filter_map(&:presence)
    end

    def strategy_confidence
      [
        commit_style_confidence,
        profile_entry("hook_manager").fetch(:confidence, 0.0).to_f
      ].max
    end

    def commit_style_confidence
      profile_entry("commit_style").fetch(:confidence, 0.0).to_f
    end

    def manager_label
      case strategy.fetch("manager_type")
      when "husky"
        "Husky"
      when "lefthook"
        "lefthook"
      when "githooks"
        "repo-managed `.githooks`"
      else
        "repo-managed"
      end
    end

    def profile_entry(key)
      return {} unless profile

      profile.fetch(:conventions).fetch(key) { {} }
    end
  end
end
