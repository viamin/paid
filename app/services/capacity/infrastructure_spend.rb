# frozen_string_literal: true

module Capacity
  # @spec INFRA-SPEND-001
  class InfrastructureSpend
    class << self
      def spent_cents(account: nil, starts_at:, ends_at: Time.current, project: nil, runner: nil,
        scope_modifier: nil, overlap_ends_at: nil)
        new(
          account: account,
          starts_at: starts_at,
          ends_at: ends_at,
          project: project,
          runner: runner,
          scope_modifier: scope_modifier,
          overlap_ends_at: overlap_ends_at
        ).spent_cents
      end

      def projected_cents_for_host(host:, starts_at:, ends_at:, now: Time.current, env: ENV)
        rate_cents_per_hour = Capacity::InfrastructureLimits.rate_cents_per_hour(host: host, env: env)
        return 0 if rate_cents_per_hour.to_i <= 0

        projection_seconds = Capacity::InfrastructureLimits.current(host: host, env: env)[:infra_spend_projection_seconds].to_i
        return 0 if projection_seconds <= 0

        remaining_seconds = [ ends_at - now, 0 ].max
        billed_seconds = [ projection_seconds, remaining_seconds ].min
        cost_for_seconds(rate_cents_per_hour, billed_seconds)
      end

      def cost_for_seconds(rate_cents_per_hour, seconds)
        return 0 if rate_cents_per_hour.to_i <= 0 || seconds.to_f <= 0

        ((rate_cents_per_hour.to_f * seconds.to_f) / 3600.0).round
      end
    end

    def initialize(account:, starts_at:, ends_at:, project: nil, runner: nil, scope_modifier: nil, overlap_ends_at: nil)
      @account = account
      @starts_at = starts_at
      @ends_at = ends_at
      @project = project
      @runner = runner
      @scope_modifier = scope_modifier
      @overlap_ends_at = overlap_ends_at
    end

    def spent_cents
      warn_about_missing_rates
      overlapping_runs.sum(Arel.sql(spend_cents_sql)).to_i
    end

    private

    attr_reader :account, :ends_at, :overlap_ends_at, :project, :runner, :scope_modifier, :starts_at

    def overlapping_runs
      @overlapping_runs ||= TenantContext.with_system_access do
        scope = AgentRun
          .joins(:project)
          .where.not(provisioning_started_at: nil)
          .where("agent_runs.provisioning_started_at < ?", ends_at)
          .where("#{overlap_ends_at_sql} >= ?", starts_at)
          .where("agent_runs.completed_at IS NOT NULL OR agent_runs.status IN (?)", AgentRun::ACTIVE_STATUSES)

        scope = scope.where(projects: { account_id: account.id }) if account
        scope = scope.where(project_id: project.id) if project
        scope = scope.where(runner_id: runner.id) if runner
        scope_modifier ? scope_modifier.call(scope) : scope
      end
    end

    def warn_about_missing_rates
      runs_missing_rate.find_each do |run|
        Rails.logger.warn(
          message: "capacity.infrastructure_spend_rate_missing",
          agent_run_id: run.id,
          container_host: run.workspace_volume_host
        )
      end
    end

    def runs_missing_rate
      overlapping_runs
        .where(rate_cents_per_hour_expression.lteq(0))
        .select(:id, :container_host, :external_metadata)
    end

    def spend_cents_sql
      @spend_cents_sql ||= <<~SQL.squish
        ROUND(
          (
            #{rate_cents_per_hour_sql} *
            GREATEST(
              EXTRACT(EPOCH FROM (
                #{overlap_ends_at_sql} -
                GREATEST(agent_runs.provisioning_started_at, #{quoted_starts_at})
              )),
              0
            )
          ) / 3600.0
        )
      SQL
    end

    def rate_cents_per_hour_sql
      @rate_cents_per_hour_sql ||= <<~SQL.squish
        COALESCE(
          NULLIF(agent_runs.external_metadata #>> '{infrastructure_spend,rate_cents_per_hour}', ''),
          '0'
        )::numeric
      SQL
    end

    def quoted_overlap_ends_at
      @quoted_overlap_ends_at ||= connection.quote(overlap_ends_at)
    end

    def rate_cents_per_hour_expression
      @rate_cents_per_hour_expression ||= Arel.sql(rate_cents_per_hour_sql)
    end

    def quoted_ends_at
      @quoted_ends_at ||= connection.quote(ends_at)
    end

    def quoted_starts_at
      @quoted_starts_at ||= connection.quote(starts_at)
    end

    def overlap_ends_at_sql
      return quoted_overlap_ends_at if overlap_ends_at.present?

      @default_overlap_ends_at_sql ||= <<~SQL.squish
        LEAST(COALESCE(agent_runs.completed_at, #{quoted_ends_at}), #{quoted_ends_at})
      SQL
    end

    def connection
      ActiveRecord::Base.connection
    end
  end
end
