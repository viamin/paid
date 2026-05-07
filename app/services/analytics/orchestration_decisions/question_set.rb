# frozen_string_literal: true

module Analytics
  module OrchestrationDecisions
    class QuestionSet
      QUESTIONS = [
        {
          key: "decision_volume_over_time",
          question: "How many orchestration decisions are being recorded over time?",
          query: "Analytics::OrchestrationDecisions::DailyVolumeQuery"
        },
        {
          key: "decision_mix_by_type",
          question: "Which decision types appear most often, based on decision-record tags?",
          query: "Analytics::OrchestrationDecisions::ByDecisionTypeQuery"
        },
        {
          key: "project_level_decision_patterns",
          question: "Which projects produce the most decisions and how broad is their decision mix?",
          query: "Analytics::OrchestrationDecisions::ByProjectQuery"
        },
        {
          key: "decision_outcomes",
          question: "How often do decisions remain active versus becoming superseded or reverted?",
          query: "Analytics::OrchestrationDecisions::SummaryQuery"
        }
      ].freeze

      def self.all
        QUESTIONS
      end
    end
  end
end
