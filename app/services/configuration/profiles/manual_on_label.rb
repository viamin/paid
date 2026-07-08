# frozen_string_literal: true

module Configuration
  module Profiles
    # Full execution, but only when a human explicitly labels an issue or PR.
    # No auto-pick; automation-on-label is the single trigger. Useful for teams
    # that want deliberate, on-demand runs with no surprise automation.
    module ManualOnLabel
      include Base

      def self.targets
        {
          "active" => true,
          "auto_pick_enabled" => false,
          "automation_on_label_enabled" => true,
          "adoption_mode" => "full_execution"
        }
      end

      def self.clarifying_questions
        [
          {
            id: "review_enabled",
            question: "Require a review pass on generated PRs before they are merged?"
          }
        ]
      end
    end
  end
end
