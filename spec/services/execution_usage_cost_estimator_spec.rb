# frozen_string_literal: true

require "rails_helper"

RSpec.describe ExecutionUsageCostEstimator do
  describe ".call / .estimate" do
    it "multiplies billed duration by the per-runner rate" do
      env = { "INFRA_SPEND_RATE_CENTS_PER_HOUR__LOCAL" => "240" }

      result = described_class.call(
        billed_duration_seconds: 3600,
        runner_backend: "local",
        env: env
      )

      expect(result.infra_cost_cents).to eq(240)
      expect(result.rate_cents_per_hour).to eq(240)
    end

    it "rounds partial hours to the nearest cent" do
      env = { "INFRA_SPEND_RATE_CENTS_PER_HOUR__LOCAL" => "120" }

      result = described_class.call(
        billed_duration_seconds: 1800,
        runner_backend: "local",
        env: env
      )

      expect(result.infra_cost_cents).to eq(60)
    end

    # @spec EXEC-USAGE-004
    it "returns zero cost when no rate is configured for the runner" do
      env = {}

      result = described_class.call(
        billed_duration_seconds: 3600,
        runner_backend: "local",
        env: env
      )

      expect(result.infra_cost_cents).to eq(0)
      expect(result.rate_cents_per_hour).to eq(0)
    end

    # @spec EXEC-USAGE-004
    it "returns zero cost when billed_duration_seconds is zero or negative" do
      env = { "INFRA_SPEND_RATE_CENTS_PER_HOUR__LOCAL" => "240" }

      zero = described_class.call(billed_duration_seconds: 0, runner_backend: "local", env: env)
      expect(zero.infra_cost_cents).to eq(0)

      negative = described_class.call(billed_duration_seconds: -10, runner_backend: "local", env: env)
      expect(negative.infra_cost_cents).to eq(0)
    end

    it "returns zero cost when runner_backend is blank" do
      env = { "INFRA_SPEND_RATE_CENTS_PER_HOUR" => "240" }

      result = described_class.call(billed_duration_seconds: 3600, runner_backend: "", env: env)

      expect(result.infra_cost_cents).to eq(0)
      expect(result.rate_cents_per_hour).to eq(0)
    end

    # @spec EXEC-USAGE-005
    it "snapshots the rate it resolved so later rate changes do not retroactively re-price the row" do
      env = { "INFRA_SPEND_RATE_CENTS_PER_HOUR__LOCAL" => "120" }

      first = described_class.call(billed_duration_seconds: 3600, runner_backend: "local", env: env)
      expect(first.infra_cost_cents).to eq(120)
      expect(first.rate_cents_per_hour).to eq(120)

      env["INFRA_SPEND_RATE_CENTS_PER_HOUR__LOCAL"] = "9999"

      # Re-calling with the new env does not mutate the previous Result — the
      # estimator is pure. The "snapshotted rate" guarantee is that callers
      # persist +rate_cents_per_hour+ onto the ExecutionUsage row.
      fresh = described_class.call(billed_duration_seconds: 3600, runner_backend: "local", env: env)
      expect(fresh.infra_cost_cents).to eq(9999)
      expect(fresh.rate_cents_per_hour).to eq(9999)

      # The previously-estimated Result still reports the rate it resolved at
      # the time of estimation.
      expect(first.rate_cents_per_hour).to eq(120)
      expect(first.infra_cost_cents).to eq(120)
    end

    it "uses the host-keyed rate when INFRA_SPEND_RATE_CENTS_PER_HOUR__<HOST> is set" do
      env = {
        "INFRA_SPEND_RATE_CENTS_PER_HOUR" => "10",
        "INFRA_SPEND_RATE_CENTS_PER_HOUR__FLY_MACHINE" => "500"
      }

      fly = described_class.call(billed_duration_seconds: 3600, runner_backend: "fly_machine", env: env)
      local = described_class.call(billed_duration_seconds: 3600, runner_backend: "local", env: env)

      expect(fly.infra_cost_cents).to eq(500)
      expect(local.infra_cost_cents).to eq(10)
    end
  end

  describe ".estimate" do
    it "is an alias for .call" do
      env = { "INFRA_SPEND_RATE_CENTS_PER_HOUR__LOCAL" => "60" }

      result = described_class.estimate(billed_duration_seconds: 1800, runner_backend: "local", env: env)
      expect(result.infra_cost_cents).to eq(30)
      expect(result.rate_cents_per_hour).to eq(60)
    end
  end
end
