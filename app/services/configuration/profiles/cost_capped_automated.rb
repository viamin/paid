# frozen_string_literal: true

module Configuration
  module Profiles
    # Automation posture that keeps throughput up while reducing spend.
    module CostCappedAutomated
      include Base

      def self.description
        "Keep auto-pick and auto-continue running for throughput, but cap spend by limiting auto-merge to dependabot and disabling auto-release, auto-enhance, and knowledge evolution."
      end

      def self.targets
        {
          "auto_pick_enabled" => true,
          "auto_scan_prs" => true,
          "automation_on_label_enabled" => true,
          "auto_merge_mode" => "dependabot_only",
          "auto_fix_merge_conflicts" => false,
          "merge_method" => "squash",
          "auto_release_granularity" => "off",
          "auto_enhance_enabled" => false,
          "auto_add_labels_enabled" => true,
          "pr_aggregation_enabled" => false,
          "auto_scan_security" => false,
          "knowledge_evolution_enabled" => false,
          "allow_bot_authored_pr_auto_merge" => false,
          "adoption_mode" => "full_execution",
          "review_paid_agent" => false,
          "review_copilot" => false,
          "quality_gate_enabled" => false
        }
      end
    end
  end
end
