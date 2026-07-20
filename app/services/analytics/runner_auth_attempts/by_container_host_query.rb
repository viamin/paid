# frozen_string_literal: true

module Analytics
  module RunnerAuthAttempts
    # Success rate grouped by (container_host, auth_source). Slices the
    # managed-vs-host comparison by Docker backend, which is the second axis
    # the RDR-041 / #2960 acceptance criteria call out.
    class ByContainerHostQuery < BaseQuery
      def call
        rows = filtered_scope
          .where.not(container_host: nil)
          .group(
            runner_auth_attempts_table[:container_host],
            runner_auth_attempts_table[:auth_source]
          )
          .order(
            runner_auth_attempts_table[:container_host].asc,
            runner_auth_attempts_table[:auth_source].asc
          )
          .pluck(
            runner_auth_attempts_table[:container_host],
            runner_auth_attempts_table[:auth_source],
            total_count,
            success_count,
            failure_count,
            Arel.sql(success_rate_sql).as("success_rate")
          )

        rows.map do |container_host, auth_source, total, success, failure, success_rate|
          {
            container_host: container_host,
            auth_source: auth_source,
            total_count: total.to_i,
            success_count: success.to_i,
            failure_count: failure.to_i,
            success_rate: success_rate&.to_f
          }
        end
      end
    end
  end
end
