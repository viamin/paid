# frozen_string_literal: true

module Configuration
  module Profiles
    # Observation posture with the broader operating-mode surface pinned off.
    module ObserveOnly
      include Base

      def self.description
        "Watch the repository without taking any automated action. Safe default while evaluating Paid."
      end

      def self.targets
        {
          "auto_pick_enabled" => false,
          "auto_scan_prs" => false,
          "automation_on_label_enabled" => false,
          "auto_merge_mode" => "off",
          "auto_fix_merge_conflicts" => false,
          "merge_method" => "squash",
          "auto_release_granularity" => "off",
          "auto_enhance_enabled" => false,
          "auto_add_labels_enabled" => true,
          "pr_aggregation_enabled" => false,
          "auto_scan_security" => false,
          "knowledge_evolution_enabled" => false,
          "allow_bot_authored_pr_auto_merge" => false,
          "adoption_mode" => "observe_only",
          "review_paid_agent" => false,
          "review_copilot" => false,
          "review_manual" => false,
          "quality_gate_enabled" => false,
          "run_concurrency_mode" => "manual",
          "agent_auto_continue" => false
        }
      end

      def self.clarifying_questions
        [
          {
            id: "active",
            question: "Keep the project active so Paid continues polling GitHub and observing activity?"
          }
        ]
      end
    end
  end
end
