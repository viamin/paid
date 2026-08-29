# frozen_string_literal: true

require "rails_helper"

RSpec.describe Dashboard::RunnerHealth do
  around do |example|
    original_store = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    example.run
  ensure
    Rails.cache = original_store
  end

  describe ".call" do
    let(:account) { create(:account) }
    let(:user) { create(:user, account: account, name: "Operator One", email: "operator@example.com") }
    let(:default_runner) { user.runners.find_by!(runner_key: Runner.default_runner_key, auth_type: "subscription") }
    let(:secondary_runner_key) { (RunnerSupport.container_executable_runner_keys - [ default_runner.runner_key ]).first || "cursor" }

    it "returns configured runner health for the account" do
      available_runner = default_runner
      rate_limited_runner = create(:runner, user: user, runner_key: secondary_runner_key, auth_type: "subscription")
      create(:runner_state, user: user, runner_name: rate_limited_runner.state_key, rate_limited_until: 10.minutes.from_now)

      stats = described_class.call(account: account)

      expect(stats).to include(
        total: 2,
        available: 1,
        rate_limited: 1,
        circuit_open: 0,
        recovering: 0,
        healthy: false
      )
      expect(stats[:runners].map(&:runner)).to eq([ rate_limited_runner.display_name, available_runner.display_name ])
      expect(stats[:runners].map(&:status)).to eq([ :rate_limited, :available ])
    end

    it "filters runners to the current account" do
      default_runner

      other_user = create(:user)
      create(:runner, user: other_user, runner_key: secondary_runner_key)

      stats = described_class.call(account: account)

      expect(stats[:total]).to eq(1)
      expect(stats[:runners].map(&:owner_email)).to eq([ user.email ])
    end

    it "uses each runner owner's configured circuit breaker timeout when checking recovery" do
      runner = default_runner
      create(:user_setting, user: user, circuit_breaker_timeout_seconds: 30)
      create(
        :runner_state,
        :circuit_open,
        user: user,
        runner_name: runner.state_key,
        circuit_opened_at: 31.seconds.ago
      )

      stats = described_class.call(account: account)

      expect(stats[:circuit_open]).to eq(0)
      expect(stats[:recovering]).to eq(1)
      expect(stats[:runners].map(&:status)).to eq([ :recovering ])
    end

    it "includes free-model availability details for free-policy opencode runners" do
      create_openrouter_free_runner_with_rate_limited_model(user:)

      summary = described_class.call(account: account)[:runners]
        .find { |entry| entry.runner_key == "opencode" }
        .free_model_summary

      expect(summary).to include(available: 1, total: 2, rate_limited: 1)
      expect(summary[:recovery_at]).to be_present
    end

    describe "dispatch circuit breaker" do
      it "returns nil when no breaker record exists for the account" do
        stats = described_class.call(account: account)
        expect(stats[:dispatch_halted]).to be_nil
      end

      it "returns nil when the breaker is closed" do
        create(:dispatch_circuit_breaker, account: account)
        stats = described_class.call(account: account)
        expect(stats[:dispatch_halted]).to be_nil
      end

      it "returns the halt payload when the breaker is open" do
        opened_at = 2.minutes.ago
        create(:dispatch_circuit_breaker, :open, account: account,
          circuit_opened_at: opened_at, trip_metadata: { "failure_rate" => 0.95 })

        stats = described_class.call(account: account)

        expect(stats[:dispatch_halted]).to include(
          state: "open",
          opened_at: be_within(1.second).of(opened_at)
        )
        expect(stats[:dispatch_halted][:metadata]).to include("failure_rate" => 0.95)
      end

      it "does not mutate the breaker when rendering the dashboard" do
        # GET requests to the dashboard must not trigger the open -> half_open
        # transition. That state change is owned by
        # DispatchCircuitBreakerRecoveryJob; rendering the dashboard after
        # the recovery timeout has elapsed should report the breaker as
        # still open until the next cron tick advances it.
        breaker = create(:dispatch_circuit_breaker, :open, account: account,
          circuit_opened_at: 10.minutes.ago)

        stats = described_class.call(account: account)

        expect(stats[:dispatch_halted][:state]).to eq("open")
        expect(breaker.reload).to be_circuit_open
      end
    end

    def create_openrouter_free_runner_with_rate_limited_model(user:)
      free_model = create(:llm_model, model_id: "high-free", provider: "deepseek", tier: "high", pricing_tier: "free",
        catalog_source: "openrouter_sync")
      create(:llm_model, model_id: "mid-free", provider: "moonshotai", tier: "mid", pricing_tier: "free",
        catalog_source: "openrouter_sync")
      api_key = create(:provider_api_key, user: user, api_service_type: "openrouter")
      runner = create(
        :runner,
        user: user,
        runner_key: "opencode",
        auth_type: "api_key",
        provider_api_key: api_key,
        config: { "opencode" => { "api_provider" => "openrouter", "model_policy" => "free" } },
        tier_model_ids: LlmModel::TIERS.index_with { free_model.model_id }
      )
      create(:runner_state, user: user, runner_name: "#{runner.state_key}:#{free_model.model_id}", rate_limited_until: 10.minutes.from_now)
      runner
    end
  end
end
