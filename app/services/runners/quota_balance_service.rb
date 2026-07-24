# frozen_string_literal: true

module Runners
  class QuotaBalanceService
    BASE_WEIGHT = 1
    CURRENT_MONTH_UNIT = "tokens"

    Result = Struct.new(:eligible_runner_ids, :updated_runner_ids, keyword_init: true) do
      def updated?
        updated_runner_ids.any?
      end
    end

    QuotaStatus = Struct.new(
      :remaining,
      :limit,
      :reset_at,
      :unit,
      :available,
      :source,
      keyword_init: true
    )

    def self.call(user:)
      new(user:).call
    end

    def initialize(user:, logger: Rails.logger, now: Time.current)
      @user = user
      @logger = logger
      @now = now
    end

    def call
      eligible = runners.filter_map do |runner|
        status = quota_status_for(runner)
        next unless status&.available && status.remaining.present?

        { runner: runner, remaining: status.remaining.to_i }
      end

      apply_weights!(eligible)
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
      runner_states[runner.state_key] ||= user.runner_states.find_or_create_by!(runner_name: runner.state_key)
    rescue ActiveRecord::RecordNotUnique
      runner_states[runner.state_key] = user.runner_states.find_by!(runner_name: runner.state_key)
    end

    def quota_status_for(runner)
      status = runner.subscription? ? subscription_quota_status_for(runner) : api_key_quota_status_for(runner)
      logger.info(
        message: "runner_quota_balance.quota_checked",
        user_id: user.id,
        runner_id: runner.id,
        runner_key: runner.runner_key,
        remaining: status&.remaining,
        limit: status&.limit,
        available: status&.available,
        unit: status&.unit,
        reset_at: status&.reset_at,
        source: status&.source
      )
      status
    rescue => e
      logger.warn(
        message: "runner_quota_balance.quota_check_failed",
        user_id: user.id,
        runner_id: runner.id,
        runner_key: runner.runner_key,
        error: e.message
      )
      nil
    end

    def subscription_quota_status_for(runner)
      provider = AgentHarness.provider(RunnerSupport.harness_runner_key_for(runner.runner_key).to_sym)
      unless provider.respond_to?(:check_quota)
        logger.info(
          message: "runner_quota_balance.quota_check_unsupported",
          user_id: user.id,
          runner_id: runner.id,
          runner_key: runner.runner_key
        )
        return nil
      end

      raw_status = provider.check_quota(env: runtime_env_for(runner.quota_check_runtime))
      persist_snapshot!(runner, normalize_quota_status(raw_status, source: "provider"))
    end

    def api_key_quota_status_for(runner)
      unless runner.monthly_budget_configured?
        return persist_snapshot!(
          runner,
          QuotaStatus.new(
            remaining: nil,
            limit: nil,
            reset_at: current_month_reset_at,
            unit: CURRENT_MONTH_UNIT,
            available: false,
            source: "monthly_budget_missing"
          )
        )
      end

      budget = runner.monthly_token_budget.to_i
      used = TokenUsage.billable
        .joins(:agent_run)
        .where(agent_runs: { runner_id: runner.id })
        .where(token_usages: { created_at: now.beginning_of_month.. })
        .sum("token_usages.input_tokens + token_usages.output_tokens")

      persist_snapshot!(
        runner,
        QuotaStatus.new(
          remaining: [ budget - used, 0 ].max,
          limit: budget,
          reset_at: current_month_reset_at,
          unit: CURRENT_MONTH_UNIT,
          available: true,
          source: "monthly_token_budget"
        )
      )
    end

    def current_month_reset_at
      now.end_of_month.end_of_day
    end

    def runtime_env_for(runtime)
      return {} unless runtime

      runtime.env.to_h.compact.except(*runtime.unset_env)
    end

    def normalize_quota_status(raw_status, source:)
      return nil unless raw_status

      QuotaStatus.new(
        remaining: Integer(raw_status.remaining, exception: false),
        limit: Integer(raw_status.limit, exception: false),
        reset_at: normalize_time(raw_status.reset_at),
        unit: raw_status.unit.to_s.presence || CURRENT_MONTH_UNIT,
        available: ActiveModel::Type::Boolean.new.cast(
          raw_status.respond_to?(:available?) ? raw_status.available? : raw_status.available
        ),
        source: source
      )
    end

    def normalize_time(value)
      return value if value.is_a?(Time) || value.is_a?(ActiveSupport::TimeWithZone)
      return nil if value.blank?

      Time.zone.parse(value.to_s)
    rescue ArgumentError
      nil
    end

    def persist_snapshot!(runner, status)
      return nil unless status

      runner_state_for(runner).record_quota_status!(
        remaining: status.remaining,
        limit: status.limit,
        reset_at: status.reset_at,
        unit: status.unit,
        available: status.available,
        source: status.source
      )
      status
    end

    def apply_weights!(eligible)
      return Result.new(eligible_runner_ids: [], updated_runner_ids: []) if eligible.empty?

      min_remaining = eligible.map { |entry| entry[:remaining] }.select(&:positive?).min || BASE_WEIGHT
      updated_runner_ids = eligible.filter_map do |entry|
        runner = entry[:runner]
        previous_weight = runner.weight
        target_weight = [ [ 1, ((entry[:remaining].to_f / min_remaining) * BASE_WEIGHT).round ].max, Runner::MAX_WEIGHT ].min
        next if previous_weight == target_weight

        runner.update_columns(weight: target_weight, updated_at: Time.current)
        runner.weight = target_weight

        logger.info(
          message: "runner_quota_balance.weight_updated",
          user_id: user.id,
          runner_id: runner.id,
          runner_key: runner.runner_key,
          previous_weight: previous_weight,
          weight: target_weight,
          remaining: entry[:remaining]
        )
        runner.id
      end

      Result.new(
        eligible_runner_ids: eligible.map { |entry| entry[:runner].id },
        updated_runner_ids: updated_runner_ids
      )
    end
  end
end
