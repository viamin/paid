# frozen_string_literal: true

module Configuration
  module Profiles
    # Throughput-oriented team posture with a human merge gate.
    module TeamReviewed
      include Base

      def self.description
        "Auto-pick and auto-enhance stay on for throughput, but human review is required and nothing auto-merges. Quality gates enforce a merge bar."
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
          "pr_aggregation_enabled" => true,
          "auto_scan_security" => true,
          "knowledge_evolution_enabled" => true,
          "allow_bot_authored_pr_auto_merge" => false,
          "adoption_mode" => "review_only",
          "review_paid_agent" => false,
          "review_copilot" => false,
          "review_manual" => true,
          "quality_gate_enabled" => true
        }
      end

      def self.clarifying_questions
        [
          {
            id: "owner_reviewer_login",
            question: "Which GitHub login must review and approve PRs before they ship?"
          }
        ]
      end

      def self.prerequisites_for(_project, targets:)
        missing = []
        missing << "Set an owner reviewer login (owner_reviewer_login) so Paid knows who must approve PRs" if targets.fetch("owner_reviewer_login", "").blank?
        missing
      end
    end
  end
end
