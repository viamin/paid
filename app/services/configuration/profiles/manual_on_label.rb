# frozen_string_literal: true

module Configuration
  module Profiles
    # On-demand posture where labeling is the only trigger.
    module ManualOnLabel
      include Base

      def self.description
        "Only pick up work when a human adds the automation label. PR scanning stays on for follow-up and optional review, but nothing auto-merges and humans stay in the loop."
      end

      def self.targets
        {
          "auto_pick_enabled" => false,
          "auto_scan_prs" => true,
          "automation_on_label_enabled" => true,
          "auto_merge_mode" => "off",
          "auto_fix_merge_conflicts" => false,
          "merge_method" => "squash",
          "auto_release_granularity" => "off",
          "auto_enhance_enabled" => false,
          "auto_add_labels_enabled" => true,
          "auto_scan_security" => false,
          "knowledge_evolution_enabled" => false,
          "allow_bot_authored_pr_auto_merge" => false,
          "adoption_mode" => "advisory",
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
            id: "review_paid_agent",
            question: "Add a paid-agent review pass on PRs created from labeled work before they can ship?"
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
