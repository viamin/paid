# frozen_string_literal: true

module Configuration
  module Profiles
    # Human-led feature factory posture (RDR-066). Humans spend their
    # attention on discovery, design, and decisions; implementation of a
    # feature runs only within an approved design.
    #
    # The profile enables the feature approval workflow for new features and
    # suggests non-strict TDD as the test-review posture. It deliberately
    # leaves auto-merge off — the owner explicitly chooses whether Paid may
    # merge PRs, and strict human test review remains selectable.
    module HumanLedFeatureFactory
      include Base

      # @spec FEATURE-APPROVAL-002
      def self.description
        "Human-led feature factory: humans approve each feature's design before its implementation runs. " \
          "Suggests non-strict TDD; auto-merge stays off unless the owner enables it."
      end

      # @spec FEATURE-APPROVAL-002
      def self.targets
        {
          "operating_mode" => "human_led_feature_factory",
          "tdd_mode" => "non_strict",
          "auto_pick_enabled" => true,
          "auto_scan_prs" => true,
          "automation_on_label_enabled" => true,
          "auto_merge_mode" => "off",
          "auto_fix_merge_conflicts" => true,
          "merge_method" => "squash",
          "auto_release_granularity" => "off",
          "auto_enhance_enabled" => true,
          "auto_add_labels_enabled" => true,
          "auto_scan_security" => true,
          "knowledge_evolution_enabled" => true,
          "allow_bot_authored_pr_auto_merge" => false,
          "adoption_mode" => "review_only",
          "review_paid_agent" => false,
          "review_copilot" => false,
          "review_manual" => false,
          "quality_gate_enabled" => false,
          "run_concurrency_mode" => "auto",
          "agent_auto_continue" => false
        }
      end

      # @spec FEATURE-APPROVAL-003
      def self.clarifying_questions
        [
          {
            id: "auto_merge_mode",
            question: "Let Paid auto-merge PRs? The mode never turns this on for you — off, dependabot-only, or all is the owner's choice."
          },
          {
            id: "tdd_mode",
            question: "Test-review posture: non-strict (automated verdict) is suggested; strict keeps a human approving the tests first."
          }
        ]
      end
    end
  end
end
