# frozen_string_literal: true

module Configuration
  module Profiles
    # A team that requires a human review gate before changes ship. Keeps the
    # project active but does not auto-pick, routes to review-only adoption,
    # and requires an owner reviewer login plus the Paid review bot App.
    module TeamReviewed
      include Base

      def self.targets
        {
          "active" => true,
          "auto_pick_enabled" => false,
          "adoption_mode" => "review_only",
          "review_enabled" => true
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
        missing << "Configure the Paid review bot GitHub App (paid-code-reviewer) before enabling reviews" unless Github::ReviewBotInstallationToken.configured?
        missing
      end
    end
  end
end
