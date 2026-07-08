# frozen_string_literal: true

module Configuration
  module Profiles
    # Observe GitHub activity without executing changes: observe-only
    # adoption, no auto-pick, no automation-on-label. The project may stay
    # active purely to keep polling/observing — that is left to the caller via
    # the +active+ clarifying question rather than forced by the profile.
    module ObserveOnly
      include Base

      def self.targets
        {
          "adoption_mode" => "observe_only",
          "auto_pick_enabled" => false,
          "automation_on_label_enabled" => false
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
