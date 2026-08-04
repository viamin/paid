# frozen_string_literal: true

module Runners
  # Refreshes upstream quota snapshots for all of a user's runners without
  # modifying runner weights. This is the proactive-polling counterpart to
  # QuotaBalanceService: both persist data to RunnerState#metadata, but this
  # service is called by the 15-minute scheduled cron for ALL users while
  # QuotaBalanceService is used only by the auto-weight rebalancer.
  class RefreshQuotaSnapshots
    CURRENT_MONTH_UNIT = "tokens"
    PROVIDER_SOURCE = "provider"
    PROVIDER_UNSUPPORTED_SOURCE = "provider_unsupported"
    PROVIDER_NO_DATA_SOURCE = "provider_no_data"
    REFRESH_FAILED_SOURCE = "refresh_failed"
    MONTHLY_BUDGET_SOURCE = "monthly_token_budget"
    MONTHLY_BUDGET_MISSING_SOURCE = "monthly_budget_missing"

    QuotaStatus = Struct.new(:remaining, :limit, :reset_at, :unit, :available, :source, :checked_at, keyword_init: true)

    def self.call(user:)
      new(user: user).call
    end

    def initialize(user:, logger: Rails.logger, now: Time.current)
      @user = user
      @logger = logger
      @now = now
    end

    def call
      runners.each { |runner| refresh_quota!(runner) }
    end

    private

    attr_reader :user, :logger, :now

    def runners
      @runners ||= user.runners.kept_only.for_agent_runs.ordered.to_a
    end

    def runner_states
      @runner_states ||= user.runner_states.index_by(&:runner_name)
    end

    def runner_state_for(runner)
      runner_states[runner.state_key] ||=
        user.runner_states.find_or_create_by!(runner_name: runner.state_key)
    rescue ActiveRecord::RecordNotUnique
      runner_states[runner.state_key] = user.runner_states.find_by!(runner_name: runner.state_key)
    end

    def refresh_quota!(runner)
      # @spec RUNNER-QUOTA-001
      status = runner.subscription? ? subscription_quota_for(runner) : api_key_quota_for(runner)
      return unless status

      runner_state_for(runner).record_quota_status!(
        remaining: status.remaining,
        limit: status.limit,
        reset_at: status.reset_at,
        unit: status.unit,
        available: status.available,
        source: status.source,
        checked_at: status.checked_at || now
      )

      logger.info(
        message: "runner_quota_snapshots.refreshed",
        user_id: user.id,
        runner_id: runner.id,
        runner_key: runner.runner_key,
        remaining: status.remaining,
        limit: status.limit,
        available: status.available,
        source: status.source
      )
    rescue => e
      persist_unavailable_snapshot!(runner, source: REFRESH_FAILED_SOURCE)
      logger.warn(
        message: "runner_quota_snapshots.refresh_failed",
        user_id: user.id,
        runner_id: runner.id,
        runner_key: runner.runner_key,
        error: e.message
      )
    end

    def subscription_quota_for(runner)
      harness_key = RunnerSupport.harness_runner_key_for(runner.runner_key).to_sym
      provider = AgentHarness.provider(harness_key)

      # @spec RUNNER-QUOTA-001
      unless provider.respond_to?(:check_quota)
        logger.info(
          message: "runner_quota_snapshots.quota_check_unsupported",
          user_id: user.id,
          runner_id: runner.id,
          runner_key: runner.runner_key
        )
        return unavailable_status(source: PROVIDER_UNSUPPORTED_SOURCE)
      end

      runtime = runner.quota_check_runtime
      env = runtime ? runtime.env.to_h.compact.except(*runtime.unset_env) : {}
      raw = provider.check_quota(env: env)
      normalize_quota(raw, source: PROVIDER_SOURCE)
    end

    def api_key_quota_for(runner)
      unless runner.monthly_budget_configured?
        return QuotaStatus.new(
          remaining: nil,
          limit: nil,
          reset_at: current_month_reset_at,
          unit: CURRENT_MONTH_UNIT,
          available: false,
          source: MONTHLY_BUDGET_MISSING_SOURCE,
          checked_at: now
        )
      end

      budget = runner.monthly_token_budget.to_i
      used = TokenUsage.billable
        .joins(:agent_run)
        .where(agent_runs: { runner_id: runner.id })
        .where(token_usages: { created_at: now.beginning_of_month.. })
        .sum("token_usages.input_tokens + token_usages.output_tokens")

      QuotaStatus.new(
        remaining: [ budget - used, 0 ].max,
        limit: budget,
        reset_at: current_month_reset_at,
        unit: CURRENT_MONTH_UNIT,
        available: true,
        source: MONTHLY_BUDGET_SOURCE,
        checked_at: now
      )
    end

    def normalize_quota(raw, source:)
      return unavailable_status(source: PROVIDER_NO_DATA_SOURCE) unless raw

      QuotaStatus.new(
        remaining: Integer(raw.remaining, exception: false),
        limit: Integer(raw.limit, exception: false),
        reset_at: parse_time(raw.reset_at),
        unit: raw.unit.to_s.presence || CURRENT_MONTH_UNIT,
        available: ActiveModel::Type::Boolean.new.cast(
          raw.respond_to?(:available?) ? raw.available? : raw.available
        ),
        source: source,
        checked_at: parse_time(raw.respond_to?(:checked_at) ? raw.checked_at : nil) || now
      )
    end

    def persist_unavailable_snapshot!(runner, source:)
      runner_state_for(runner).record_quota_status!(
        remaining: nil,
        limit: nil,
        reset_at: nil,
        unit: CURRENT_MONTH_UNIT,
        available: false,
        source: source,
        checked_at: now
      )
    end

    def unavailable_status(source:)
      QuotaStatus.new(
        remaining: nil,
        limit: nil,
        reset_at: nil,
        unit: CURRENT_MONTH_UNIT,
        available: false,
        source: source,
        checked_at: now
      )
    end

    def parse_time(value)
      return value if value.is_a?(Time) || value.is_a?(ActiveSupport::TimeWithZone)
      return nil if value.blank?

      Time.zone.parse(value.to_s)
    rescue ArgumentError
      nil
    end

    def current_month_reset_at
      now.end_of_month.end_of_day
    end
  end
end
