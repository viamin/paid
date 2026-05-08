# frozen_string_literal: true

module Analytics
  module OrchestrationDecisions
    class BaseQuery
      DEFAULT_DECISION_STATUS = "applied"

      def initialize(relation: OrchestrationDecision.all, filters: {})
        @relation = relation
        @filters = filters
      end

      private

      attr_reader :relation, :filters

      def filtered_scope
        scope = relation
        scope = scope.where(project_id: project_ids) if project_ids.any?
        scope = scope.where("orchestration_decisions.created_at >= ?", filters[:from]) if filters[:from].present?
        scope = scope.where("orchestration_decisions.created_at <= ?", filters[:to]) if filters[:to].present?
        scope = scope.where(decision_type: decision_types) if decision_types.any?
        scope
      end

      def project_ids
        @project_ids ||= Array(filters[:project_ids]).filter_map(&:presence).uniq
      end

      def decision_types
        @decision_types ||= Array(filters[:decision_types]).filter_map do |value|
          normalize_decision_type(value)
        end.uniq
      end

      def normalize_decision_type(value)
        value.to_s.strip.downcase.presence
      end

      def orchestration_decisions_table
        OrchestrationDecision.arel_table
      end

      def projects_table
        Project.arel_table
      end

      def agent_runs_table
        AgentRun.arel_table
      end

      def distinct_count(expression)
        Arel::Nodes::Count.new([ expression ], true)
      end

      def distinct_status_count(status)
        quoted_status = ActiveRecord::Base.connection.quote(status)
        Arel.sql(
          "COUNT(DISTINCT CASE " \
          "WHEN COALESCE(orchestration_decisions.context ->> 'decision_status', '#{DEFAULT_DECISION_STATUS}') = #{quoted_status} " \
          "THEN orchestration_decisions.id END)"
        )
      end

      def distinct_completed_run_count
        Arel.sql(
          "COUNT(DISTINCT CASE " \
          "WHEN agent_runs.status = 'completed' THEN agent_runs.id END)"
        )
      end
    end
  end
end
