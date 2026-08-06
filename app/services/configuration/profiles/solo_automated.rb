# frozen_string_literal: true

module Configuration
  module Profiles
    # Broad, high-autonomy posture for a solo operator.
    module SoloAutomated
      include Base

      def self.description
        "Maximum autonomy for a solo developer: auto-pick, auto-merge everything, paid-agent review, and full auto-release."
      end

      def self.targets
        {
          "auto_pick_enabled" => true,
          "auto_scan_prs" => true,
          "automation_on_label_enabled" => true,
          "auto_merge_mode" => "all",
          "auto_fix_merge_conflicts" => true,
          "merge_method" => "squash",
          "auto_release_granularity" => "all",
          "auto_enhance_enabled" => true,
          "auto_add_labels_enabled" => true,
          "pr_aggregation_enabled" => true,
          "auto_scan_security" => true,
          "knowledge_evolution_enabled" => true,
          "allow_bot_authored_pr_auto_merge" => true,
          "adoption_mode" => "full_execution",
          "review_paid_agent" => true,
          "review_copilot" => false,
          "review_manual" => false,
          "quality_gate_enabled" => false
        }
      end

      def self.clarifying_questions
        [
          {
            id: "quality_gate_enabled",
            question: "Block PR creation when the quality gate composite score drops below threshold?"
          }
        ]
      end

      def self.prerequisites_for(_project, targets:)
        missing = []
        if targets["review_paid_agent"] && !Github::ReviewBotInstallationToken.configured?
          missing << "Configure the Paid review bot GitHub App (paid-code-reviewer) before enabling paid-agent review"
        end
        missing
      end
    end
  end
end
