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
          question: "Which orchestration decision types appear most often across workflows, retries, and selection paths?",
          query: "Analytics::OrchestrationDecisions::ByDecisionTypeQuery"
        },
        {
          key: "project_level_decision_patterns",
          question: "Which projects produce the most decisions and how broad is their decision mix?",
          query: "Analytics::OrchestrationDecisions::ByProjectQuery"
        },
        {
          key: "decision_outcomes",
          question: "How often are orchestration decisions applied, skipped as no-ops, or recorded as failures?",
          query: "Analytics::OrchestrationDecisions::SummaryQuery"
        }
      ].freeze

      def self.all
        QUESTIONS
      end
    end
  end
end
