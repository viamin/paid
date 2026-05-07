# frozen_string_literal: true

module Analytics
  module OrchestrationDecisions
    class Report
      def initialize(relation: DecisionRecord.all, filters: {})
        @relation = relation
        @filters = filters
      end

      def self.call(...)
        new(...).call
      end

      def call
        {
          questions: QuestionSet.all,
          filters: serialized_filters,
          summary: SummaryQuery.new(relation: relation, filters: filters).call,
          by_project: ByProjectQuery.new(relation: relation, filters: filters).call,
          by_decision_type: ByDecisionTypeQuery.new(relation: relation, filters: filters).call,
          daily_volume: DailyVolumeQuery.new(relation: relation, filters: filters).call
        }
      end

      private

      attr_reader :relation, :filters

      def serialized_filters
        {
          from: filters[:from],
          to: filters[:to],
          project_ids: Array(filters[:project_ids]).compact,
          decision_types: Array(filters[:decision_types]).filter_map(&:presence)
        }
      end
    end
  end
end
