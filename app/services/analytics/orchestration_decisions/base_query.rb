# frozen_string_literal: true

module Analytics
  module OrchestrationDecisions
    class BaseQuery
      DEFAULT_DECISION_STATUS = OrchestrationDecision::DEFAULT_DECISION_STATUS

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
        distinct_count(
          Arel::Nodes::Case.new
            .when(status_predicate(status))
            .then(orchestration_decisions_table[:id])
        )
      end

      def status_count(status)
        Arel::Nodes::NamedFunction.new(
          "SUM",
          [
            Arel::Nodes::Case.new
              .when(status_predicate(status))
              .then(Arel::Nodes.build_quoted(1))
              .else(Arel::Nodes.build_quoted(0))
          ]
        )
      end

      def grouped_statuses(group)
        OrchestrationDecision::ANALYTICS_STATUS_GROUPS.fetch(group)
      end

      def decision_status_sql
        "COALESCE(orchestration_decisions.context ->> 'decision_status', '#{DEFAULT_DECISION_STATUS}')"
      end

      def decision_status_node
        Arel::Nodes::NamedFunction.new(
          "COALESCE",
          [
            Arel::Nodes::InfixOperation.new(
              "->>",
              orchestration_decisions_table[:context],
              Arel::Nodes.build_quoted("decision_status")
            ),
            Arel::Nodes.build_quoted(DEFAULT_DECISION_STATUS)
          ]
        )
      end

      def status_predicate(status)
        decision_status_node.in(Array(status))
      end

      def total_count
        distinct_count(orchestration_decisions_table[:id])
      end

      def project_count
        distinct_count(orchestration_decisions_table[:project_id])
      end

      def actor_count
        distinct_count(orchestration_decisions_table[:actor])
      end

      def decision_type_count
        distinct_count(orchestration_decisions_table[:decision_type])
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
