# frozen_string_literal: true

module Dashboard
  class RunnerHealth
    CACHE_TTL = 20.seconds

    RunnerStatus = Struct.new(
      :runner,
      :runner_key,
      :owner_name,
      :owner_email,
      :auth_type,
      :status,
      :status_label,
      :available,
      :failure_count,
      :rate_limited_until,
      :free_model_summary,
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

      configured_runners.map do |runner|
        build_runner_status(runner, state_by_runner[runner.state_key])
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
        .where(users: { account_id: account.id })
        .includes(:user)
    end

    def build_runner_status(runner, state)
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
        runner_key: runner.runner_key,
        owner_name: runner.user.name.presence || runner.user.email,
        owner_email: runner.user.email,
        auth_type: runner.api_key? ? "API Key" : "Subscription",
        status: status,
        status_label: status.to_s.humanize,
        available: status == :available,
        failure_count: state&.failure_count || 0,
        rate_limited_until: state&.rate_limited_until,
        free_model_summary: free_model_summary_for(runner, status: status, state: state)
      )
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

    def free_model_summary_for(runner, status:, state:)
      return unless runner.runner_key == Runner::OPENROUTER_FREE_RUNNER_KEY

      total = LlmModel.free.active.count
      return { available: 0, total: 0, rate_limited: 0, recovery_at: nil } if total.zero?

      prefix = "#{runner.state_key}:"
      model_states = runner_states.select { |entry| entry.user_id == runner.user_id && entry.runner_name.start_with?(prefix) }
      rate_limited_states = model_states.select(&:rate_limited?)
      rate_limited = if rate_limited_states.any?
        rate_limited_states.count
      elsif status == :rate_limited
        total
      else
        0
      end

      {
        available: [ total - rate_limited, 0 ].max,
        total: total,
        rate_limited: rate_limited,
        recovery_at: rate_limited_states.map(&:rate_limited_until).compact.min || state&.rate_limited_until
      }
    end

    def self.default_circuit_breaker_timeout
      UserSetting.column_defaults["circuit_breaker_timeout_seconds"]
    end
  end
end
