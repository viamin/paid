# frozen_string_literal: true

module Configuration
  module Profiles
    # High-quality posture with automated review and a strict merge gate.
    module QualityStrict
      include Base

      def self.description
        "Prioritize output quality: paid-agent review and an enabled quality gate gate every change, with auto-enhance filtering issues before work starts. No auto-merge."
      end

      def self.targets
        {
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
          "review_paid_agent" => true,
          "review_copilot" => false,
          "review_manual" => false,
          "quality_gate_enabled" => true,
          "run_concurrency_mode" => "manual",
          "agent_auto_continue" => false
        }
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
