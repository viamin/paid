# frozen_string_literal: true

module Dashboard
  class RunnerHealth
    CACHE_TTL = 20.seconds
    ATTEMPT_WINDOW = 7.days

    RunnerStatus = Struct.new(
      :runner,
      :owner_name,
      :owner_email,
      :auth_type,
      :status,
      :status_label,
      :available,
      :failure_count,
      :attempt_count,
      :rate_limited_until,
      keyword_init: true
    )

    def self.call(...)
      new(...).call
    end

    def initialize(account:)
      @account = account
    end

    def call
      Rails.cache.fetch(cache_key, expires_in: CACHE_TTL) { build_payload }
    end

    private

    attr_reader :account

    def build_payload
      runners = runner_rows

      {
        runners: runners,
        total: runners.size,
        available: runners.count(&:available),
        rate_limited: runners.count { |runner| runner.status == :rate_limited },
        circuit_open: runners.count { |runner| runner.status == :circuit_open },
        recovering: runners.count { |runner| runner.status == :recovering },
        healthy: runners.any? && runners.all?(&:available)
      }
    end

    def runner_rows
      state_by_runner = runner_states.index_by(&:runner_name)
      metrics_by_runner = recent_attempt_metrics_by_runner

      configured_runners.map do |runner|
        build_runner_status(
          runner,
          state_by_runner[runner.state_key],
          recent_metrics: metrics_by_runner.fetch(runner.state_key, {})
        )
      end.sort_by { |runner| [ status_priority(runner.status), runner.runner.downcase, runner.owner_email.downcase ] }
    end

    def configured_runners
      @configured_runners ||= Runner
        .joins(:user)
        .where(users: { account_id: account.id })
        .for_agent_runs
        .includes(user: :user_setting)
        .ordered
    end

    def runner_states
      @runner_states ||= RunnerState
        .joins(:user)
        .where(users: { account_id: account.id }, runner_name: configured_runners.map(&:state_key))
        .includes(:user)
    end

    def build_runner_status(runner, state, recent_metrics:)
      state&.check_circuit_recovery!(timeout: circuit_breaker_timeout_for(runner))

      status =
        if state&.rate_limited?
          :rate_limited
        elsif state&.circuit_open?
          :circuit_open
        elsif state&.circuit_half_open?
          :recovering
        else
          :available
        end

      RunnerStatus.new(
        runner: runner.display_name,
        owner_name: runner.user.name.presence || runner.user.email,
        owner_email: runner.user.email,
        auth_type: runner.api_key? ? "API Key" : "Subscription",
        status: status,
        status_label: status.to_s.humanize,
        available: status == :available,
        failure_count: recent_metrics.fetch(:failure_count, 0),
        attempt_count: recent_metrics.fetch(:attempt_count, 0),
        rate_limited_until: state&.rate_limited_until
      )
    end

    def recent_attempt_metrics_by_runner
      configured_state_keys = configured_runners.map(&:state_key)
      return {} if configured_state_keys.empty?

      normalized_attempt_runner_sql = AgentRun.normalize_provider_sql("attempt->>'provider'")

      account_runs
        .where(created_at: (ATTEMPT_WINDOW * 2).ago..)
        .joins("CROSS JOIN LATERAL jsonb_array_elements(COALESCE(agent_runs.runners_attempted, '[]'::jsonb)) AS attempt")
        .where(<<~SQL, ATTEMPT_WINDOW.ago)
          COALESCE(
            NULLIF(attempt->>'attempted_at', '')::timestamptz,
            agent_runs.created_at
          ) >= ?
        SQL
        .where("#{normalized_attempt_runner_sql} IN (?)", configured_state_keys)
        .group(Arel.sql(normalized_attempt_runner_sql))
        .pluck(
          Arel.sql(normalized_attempt_runner_sql),
          Arel.sql("COUNT(*)::integer"),
          Arel.sql("COUNT(*) FILTER (WHERE NOT COALESCE((attempt->>'success')::boolean, false))::integer")
        ).each_with_object({}) do |(runner_key, attempts, failures), metrics|
          metrics[runner_key] = {
            attempt_count: attempts,
            failure_count: failures
          }
        end
    end

    def account_runs
      AgentRun.joins(:project).where(projects: { account_id: account.id })
    end

    def circuit_breaker_timeout_for(runner)
      runner.user.user_setting&.circuit_breaker_timeout_seconds || self.class.default_circuit_breaker_timeout
    end

    def status_priority(status)
      case status
      when :rate_limited then 0
      when :circuit_open then 1
      when :recovering then 2
      else 3
      end
    end

    def cache_key
      "dashboard/runner_health/#{account.id}"
    end

    def self.default_circuit_breaker_timeout
      UserSetting.column_defaults["circuit_breaker_timeout_seconds"]
    end
  end
end
