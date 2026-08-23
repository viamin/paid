# frozen_string_literal: true

module Capacity
  # @spec INFRA-SPEND-001
  class InfrastructureSpend
    class << self
      def spent_cents(account: nil, starts_at:, ends_at: Time.current, project: nil, runner: nil)
        new(
          account: account,
          starts_at: starts_at,
          ends_at: ends_at,
          project: project,
          runner: runner
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

    def initialize(account:, starts_at:, ends_at:, project: nil, runner: nil)
      @account = account
      @starts_at = starts_at
      @ends_at = ends_at
      @project = project
      @runner = runner
    end

    def spent_cents
      runs.sum { |run| spend_for_run(run) }
    end

    private

    attr_reader :account, :ends_at, :project, :runner, :starts_at

    def runs
      @runs ||= TenantContext.with_system_access do
        scope = AgentRun
          .joins(:project)
          .where.not(provisioning_started_at: nil)
          .where("agent_runs.provisioning_started_at < ?", ends_at)
          .where("agent_runs.completed_at IS NULL OR agent_runs.completed_at >= ?", starts_at)
          .where("agent_runs.completed_at IS NOT NULL OR agent_runs.status IN (?)", AgentRun::ACTIVE_STATUSES)

        scope = scope.where(projects: { account_id: account.id }) if account
        scope = scope.where(project_id: project.id) if project
        scope = scope.where(runner_id: runner.id) if runner
        scope.to_a
      end
    end

    def spend_for_run(run)
      run_start = [ run.provisioning_started_at, starts_at ].compact.max
      run_end = [ terminal_time_for(run), ends_at ].compact.min
      return 0 if run_start.blank? || run_end.blank? || run_end <= run_start

      self.class.cost_for_seconds(rate_cents_per_hour_for_run(run), run_end - run_start)
    end

    def terminal_time_for(run)
      return run.completed_at if run.completed_at.present?
      return ends_at if AgentRun::ACTIVE_STATUSES.include?(run.status)

      nil
    end

    # Historical spend accounting must stay fixed once computed. Falling back
    # to the *current* Capacity::InfrastructureLimits config for a run that
    # never had a rate stamped into external_metadata (runs in flight when
    # this feature deployed, or any run whose host rate changes later) would
    # reprice that run every time this method runs, making dashboards and
    # threshold checks drift as the env var changes rather than reflecting
    # what was actually true when the run executed. Treat un-stamped runs as
    # uncosted instead of guessing from live config.
    def rate_cents_per_hour_for_run(run)
      stored_rate = run.external_metadata.dig("infrastructure_spend", "rate_cents_per_hour")
      return stored_rate.to_i if stored_rate.to_i.positive?

      Rails.logger.warn(
        message: "capacity.infrastructure_spend_rate_missing",
        agent_run_id: run.id,
        container_host: run.workspace_volume_host
      )
      0
    end
  end
end
