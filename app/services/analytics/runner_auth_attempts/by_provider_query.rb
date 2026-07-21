# frozen_string_literal: true

module Analytics
  module RunnerAuthAttempts
    # Success rate grouped by (provider, auth_source). The primary comparison
    # the RDR-041 / #2960 acceptance criteria call out: "managed and legacy
    # local auth attempts can be compared by provider and Docker host".
    class ByProviderQuery < BaseQuery
      def call
        rows = filtered_scope
          .group(
            runner_auth_attempts_table[:runner_key],
            runner_auth_attempts_table[:auth_source]
          )
          .order(
            runner_auth_attempts_table[:runner_key].asc,
            runner_auth_attempts_table[:auth_source].asc
          )
          .pluck(
            runner_auth_attempts_table[:runner_key],
            runner_auth_attempts_table[:auth_source],
            total_count,
            success_count,
            failure_count,
            average_duration_ms
          )

        rows.map do |runner_key, auth_source, total, success, failure, avg_duration|
          total_count = total.to_i
          {
            runner_key: runner_key,
            auth_source: auth_source,
            total_count: total_count,
            success_count: success.to_i,
            failure_count: failure.to_i,
            avg_duration_ms: avg_duration&.to_f,
            success_rate: success_rate(success_count: success.to_i, total_count: total_count)
          }
        end
      end
    end
  end
end
