# frozen_string_literal: true

module Configuration
  module Profiles
    # A single developer who wants Paid to run end-to-end without a review
    # gate: project active, auto-pick on, full execution, no human/bot review.
    module SoloAutomated
      include Base

      def self.targets
        {
          "active" => true,
          "auto_pick_enabled" => true,
          "automation_on_label_enabled" => true,
          "adoption_mode" => "full_execution",
          "review_enabled" => false
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
    end
  end
end
