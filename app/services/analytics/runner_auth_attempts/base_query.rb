# frozen_string_literal: true

module Analytics
  module RunnerAuthAttempts
    # Shared filtering and helpers for RunnerAuthAttempt analytics queries.
    # Mirrors Analytics::OrchestrationDecisions::BaseQuery so the same conventions
    # (filters, project scoping, arel table helpers) apply here.
    class BaseQuery
      DEFAULT_RESULT_GROUP = "all".freeze

      def initialize(relation: RunnerAuthAttempt.all, filters: {})
        @relation = relation
        @filters = filters
      end

      private

      attr_reader :relation, :filters

      def filtered_scope
        scope = relation
        scope = scope.where(project_id: project_ids) if project_ids.any?
        scope = scope.where(account_id: account_ids) if account_ids.any?
        scope = scope.where(runner_key: runner_keys) if runner_keys.any?
        scope = scope.where(auth_source: auth_sources) if auth_sources.any?
        scope = scope.where(container_host: container_hosts) if container_hosts.any?
        scope = scope.where(attempt_stage: attempt_stages) if attempt_stages.any?
        scope = scope.where(result: results) if results.any?
        scope = scope.where("attempted_at >= ?", filters[:from]) if filters[:from].present?
        scope = scope.where("attempted_at <= ?", filters[:to]) if filters[:to].present?
        scope
      end

      def project_ids
        @project_ids ||= Array(filters[:project_ids]).filter_map(&:presence).uniq
      end

      def account_ids
        @account_ids ||= Array(filters[:account_ids]).filter_map(&:presence).uniq
      end

      def runner_keys
        @runner_keys ||= normalize_array(filters[:runner_keys])
      end

      def auth_sources
        @auth_sources ||= normalize_array(filters[:auth_sources])
      end

      def container_hosts
        @container_hosts ||= normalize_array(filters[:container_hosts])
      end

      def attempt_stages
        @attempt_stages ||= normalize_array(filters[:attempt_stages])
      end

      def results
        @results ||= normalize_array(filters[:results])
      end

      def normalize_array(value)
        Array(value).map { |entry| entry.to_s.strip.presence }.compact.uniq
      end

      def runner_auth_attempts_table
        RunnerAuthAttempt.arel_table
      end

      def projects_table
        Project.arel_table
      end

      def accounts_table
        Account.arel_table
      end

      def total_count
        Arel::Nodes::Count.new([ runner_auth_attempts_table[:id] ], true)
      end

      def success_count
        Arel::Nodes::NamedFunction.new(
          "SUM",
          [
            Arel::Nodes::Case.new
              .when(runner_auth_attempts_table[:result].in(RunnerAuthAttempt::SUCCESS_RESULTS))
              .then(Arel::Nodes.build_quoted(1))
              .else(Arel::Nodes.build_quoted(0))
          ]
        )
      end

      def failure_count
        Arel::Nodes::NamedFunction.new(
          "SUM",
          [
            Arel::Nodes::Case.new
              .when(runner_auth_attempts_table[:result].in(RunnerAuthAttempt::FAILURE_RESULTS))
              .then(Arel::Nodes.build_quoted(1))
              .else(Arel::Nodes.build_quoted(0))
          ]
        )
      end

      def distinct_project_count
        Arel::Nodes::Count.new([ runner_auth_attempts_table[:project_id] ], true)
      end

      def distinct_account_count
        Arel::Nodes::Count.new([ runner_auth_attempts_table[:account_id] ], true)
      end

      def distinct_container_host_count
        Arel::Nodes::Count.new([ runner_auth_attempts_table[:container_host] ], true)
      end

      def distinct_provider_count
        Arel::Nodes::Count.new([ runner_auth_attempts_table[:runner_key] ], true)
      end

      def average_duration_ms
        Arel::Nodes::NamedFunction.new(
          "AVG",
          [ runner_auth_attempts_table[:duration_ms] ]
        )
      end

      # Computes success_rate from already-aggregated success / total counts so
      # callers don't have to drop a hand-built SQL CASE INTO the SELECT list.
      # A zero total returns nil rather than 0/0 so dashboards can distinguish
      # "no attempts" from "every attempt failed".
      def success_rate(success_count:, total_count:)
        return nil if total_count.to_i.zero?

        success_count.to_f / total_count
      end
    end
  end
end
