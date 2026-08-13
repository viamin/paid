# frozen_string_literal: true

module Analytics
  module RunnerAuthAttempts
    # Breakdown of failure reasons. Surfaces named codes (auth_expired,
    # refresh_failed, materialization_failed, remote-rejected) so dashboards
    # can distinguish the four buckets the RDR-041 / #2960 acceptance
    # criteria call out.
    class FailureReasonBreakdownQuery < BaseQuery
      def call
        rows = filtered_scope
          .where(runner_auth_attempts_table[:result].in(RunnerAuthAttempt::FAILURE_RESULTS))
          .group(
            runner_auth_attempts_table[:failure_reason],
            runner_auth_attempts_table[:result]
          )
          .order(total_count.desc)
          .pluck(
            runner_auth_attempts_table[:failure_reason],
            runner_auth_attempts_table[:result],
            total_count,
            distinct_project_count,
            distinct_provider_count,
            distinct_container_host_count
          )

        rows.map do |reason, result, total, project_count, provider_count, container_host_count|
          {
            failure_reason: reason,
            result: result,
            total_count: total.to_i,
            project_count: project_count.to_i,
            provider_count: provider_count.to_i,
            container_host_count: container_host_count.to_i
          }
        end
      end
    end
  end
end
