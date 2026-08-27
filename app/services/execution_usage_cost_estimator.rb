# frozen_string_literal: true

# Deterministic, side-effect-free infrastructure cost estimator.
#
# Given a per-runner rate resolved from
# +Capacity::InfrastructureLimits.rate_cents_per_hour(host:)+ and the
# provider-billed duration of the resource, returns the estimated cost in
# cents. Used both to populate +ExecutionUsage#infra_cost_cents+ on
# termination and to backfill historical runs without touching the
# admission path.
#
# The estimator is intentionally a pure function: no database writes,
# no telemetry, no side effects. The rate it resolves is snapshotted
# onto the +ExecutionUsage+ row by the caller so later env-var changes
# do not retroactively re-price historical runs (matching the
# +Capacity::InfrastructureSpend+ admission-time stamp invariant).
class ExecutionUsageCostEstimator
  Result = Data.define(:infra_cost_cents, :rate_cents_per_hour) do
    def self.zero(rate_cents_per_hour: 0)
      new(infra_cost_cents: 0, rate_cents_per_hour: rate_cents_per_hour.to_i)
    end
  end

  def self.call(...)
    new(...).call
  end

  def initialize(billed_duration_seconds:, runner_backend:, rate_cents_per_hour: nil, env: ENV)
    @billed_duration_seconds = billed_duration_seconds
    @runner_backend = runner_backend
    @rate_cents_per_hour = rate_cents_per_hour
    @env = env
  end

  # @spec EXEC-USAGE-004
  # @spec EXEC-USAGE-005
  def call
    duration = billed_duration_seconds.to_i
    rate = resolved_rate

    return Result.zero(rate_cents_per_hour: rate) if duration <= 0 || rate <= 0

    Result.new(
      infra_cost_cents: ((rate.to_f * duration) / 3600.0).round,
      rate_cents_per_hour: rate
    )
  end

  private

  attr_reader :billed_duration_seconds, :runner_backend, :rate_cents_per_hour, :env

  def resolved_rate
    stamped_rate = rate_cents_per_hour.to_i
    return stamped_rate if stamped_rate.positive?
    return 0 if runner_backend.blank?

    Capacity::InfrastructureLimits.rate_cents_per_hour(host: runner_backend, env: env).to_i
  end
end
