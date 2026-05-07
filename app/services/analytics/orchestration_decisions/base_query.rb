# frozen_string_literal: true

module Analytics
  module OrchestrationDecisions
    class BaseQuery
      UNCATEGORIZED_DECISION_TYPE = "uncategorized"

      def initialize(relation: DecisionRecord.all, filters: {})
        @relation = relation
        @filters = filters
      end

      private

      attr_reader :relation, :filters

      def filtered_scope
        scope = relation
        scope = scope.where(project_id: project_ids) if project_ids.any?
        scope = scope.where("decision_records.created_at >= ?", filters[:from]) if filters[:from].present?
        scope = scope.where("decision_records.created_at <= ?", filters[:to]) if filters[:to].present?
        scope = apply_decision_type_filter(scope)
        scope
      end

      def apply_decision_type_filter(scope)
        return scope if decision_types.empty?

        clauses = []
        binds = []

        if tagged_decision_types.any?
          clauses << <<~SQL.squish
            EXISTS (
              SELECT 1
              FROM jsonb_array_elements_text(decision_records.tags) AS tag(value)
              WHERE NULLIF(LOWER(BTRIM(tag.value)), '') IN (?)
            )
          SQL
          binds << tagged_decision_types
        end

        if uncategorized_selected?
          clauses << <<~SQL.squish
            NOT EXISTS (
              SELECT 1
              FROM jsonb_array_elements_text(decision_records.tags) AS tag(value)
              WHERE NULLIF(LOWER(BTRIM(tag.value)), '') IS NOT NULL
            )
          SQL
        end

        scope.where([ clauses.join(" OR "), *binds ])
      end

      def project_ids
        @project_ids ||= Array(filters[:project_ids]).filter_map(&:presence).uniq
      end

      def decision_types
        @decision_types ||= Array(filters[:decision_types]).filter_map do |value|
          normalize_decision_type(value)
        end.uniq
      end

      def tagged_decision_types
        decision_types - [ UNCATEGORIZED_DECISION_TYPE ]
      end

      def uncategorized_selected?
        decision_types.include?(UNCATEGORIZED_DECISION_TYPE)
      end

      def normalize_decision_type(value)
        value.to_s.strip.downcase.presence
      end

      def decision_types_join_sql
        <<~SQL.squish
          LEFT JOIN LATERAL (
            SELECT DISTINCT NULLIF(LOWER(BTRIM(tag.value)), '') AS decision_type
            FROM jsonb_array_elements_text(decision_records.tags) AS tag(value)
            WHERE NULLIF(LOWER(BTRIM(tag.value)), '') IS NOT NULL
          ) decision_types ON TRUE
        SQL
      end

      def decision_type_sql
        "COALESCE(decision_types.decision_type, '#{UNCATEGORIZED_DECISION_TYPE}')"
      end
    end
  end
end
