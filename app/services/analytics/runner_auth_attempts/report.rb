# frozen_string_literal: true

module Analytics
  module RunnerAuthAttempts
    # Composite report for runner auth attempt telemetry.
    #
    # Mirrors Analytics::OrchestrationDecisions::Report so dashboards can
    # consume both with consistent shape. The report answers the
    # RDR-041 / #2960 acceptance criteria:
    #
    #   - managed and legacy local auth attempts can be compared by
    #     provider and Docker host (SummaryQuery, ByProviderQuery,
    #     ByContainerHostQuery)
    #   - auth-expired, refresh-failed, materialization-failed, and
    #     remote-rejected outcomes are distinguishable (FailureReasonBreakdownQuery)
    #   - telemetry records are account/project scoped (filters + filters serializer)
    class Report
      def initialize(relation: RunnerAuthAttempt.all, filters: {})
        @relation = relation
        @filters = filters
      end

      def self.call(...)
        new(...).call
      end

      def call
        {
          filters: serialized_filters,
          summary: SummaryQuery.new(relation: relation, filters: filters).call,
          by_provider: ByProviderQuery.new(relation: relation, filters: filters).call,
          by_container_host: ByContainerHostQuery.new(relation: relation, filters: filters).call,
          failure_reason_breakdown: FailureReasonBreakdownQuery.new(relation: relation, filters: filters).call
        }
      end

      private

      attr_reader :relation, :filters

      def serialized_filters
        {
          from: filters[:from],
          to: filters[:to],
          account_ids: Array(filters[:account_ids]).compact,
          project_ids: Array(filters[:project_ids]).compact,
          runner_keys: Array(filters[:runner_keys]).filter_map(&:presence),
          auth_sources: Array(filters[:auth_sources]).filter_map(&:presence),
          container_hosts: Array(filters[:container_hosts]).filter_map(&:presence),
          attempt_stages: Array(filters[:attempt_stages]).filter_map(&:presence),
          results: Array(filters[:results]).filter_map(&:presence)
        }
      end
    end
  end
end
