# frozen_string_literal: true

module Analytics
  module RunnerAuthAttempts
    # Top-line summary of runner auth attempts over the filtered window.
    # Mirrors Analytics::OrchestrationDecisions::SummaryQuery so dashboards can
    # consume both with consistent shape.
    class SummaryQuery < BaseQuery
      def call
        row = filtered_scope
          .select(
            total_count.as("total_count"),
            success_count.as("success_count"),
            failure_count.as("failure_count"),
            distinct_project_count.as("project_count"),
            distinct_account_count.as("account_count"),
            distinct_provider_count.as("provider_count"),
            distinct_container_host_count.as("container_host_count"),
            average_duration_ms.as("avg_duration_ms"),
            Arel.sql("COUNT(DISTINCT agent_run_id) AS linked_agent_run_count"),
            Arel.sql("COUNT(DISTINCT runner_credential_id) AS linked_runner_credential_count")
          )
          .take

        return empty_result unless row

        {
          total_count: row.total_count.to_i,
          success_count: row.success_count.to_i,
          failure_count: row.failure_count.to_i,
          project_count: row.project_count.to_i,
          account_count: row.account_count.to_i,
          provider_count: row.provider_count.to_i,
          container_host_count: row.container_host_count.to_i,
          linked_agent_run_count: row.linked_agent_run_count.to_i,
          linked_runner_credential_count: row.linked_runner_credential_count.to_i,
          avg_duration_ms: row.avg_duration_ms&.to_f,
          success_rate: success_rate(
            success_count: row.success_count.to_i,
            total_count: row.total_count.to_i
          )
        }
      end

      private

      def empty_result
        {
          total_count: 0,
          success_count: 0,
          failure_count: 0,
          project_count: 0,
          account_count: 0,
          provider_count: 0,
          container_host_count: 0,
          linked_agent_run_count: 0,
          linked_runner_credential_count: 0,
          avg_duration_ms: nil,
          success_rate: nil
        }
      end
    end
  end
end
