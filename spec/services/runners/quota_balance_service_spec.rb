# frozen_string_literal: true

require "rails_helper"

RSpec.describe Runners::QuotaBalanceService do
  describe ".call" do
    let(:user) { create(:user) }
    let(:model_id) { "moonshotai/kimi-k2-0905" }
    let(:api_key) { create(:provider_api_key, user: user, api_service_type: "openrouter") }

    def build_api_runner(key:, budget:, weight:)
      create(
        :runner,
        user: user,
        runner_key: key,
        auth_type: "api_key",
        provider_api_key: api_key,
        monthly_token_budget: budget,
        weight: weight,
        config: { key => { "api_provider" => "openrouter", "model" => model_id } }
      )
    end

    def create_usage_for(runner, tokens:)
      project = create(:project, account: user.account, created_by: user)
      agent_run = create(:agent_run, runner: runner, project: project)
      create(:token_usage, agent_run: agent_run, input_tokens: tokens, output_tokens: 0)
    end

    it "balances API-key runner weights by remaining monthly budget" do
      high = build_api_runner(key: "opencode", budget: 1_000, weight: 1)
      low = build_api_runner(key: "kilocode", budget: 600, weight: 1)
      create_usage_for(high, tokens: 200)
      create_usage_for(low, tokens: 200)

      described_class.call(user: user)

      expect(high.reload.weight).to eq(2)
      expect(low.reload.weight).to eq(1)
      expect(user.runner_states.find_by!(runner_name: high.routing_key).quota_status_snapshot).to include(
        "remaining" => 800,
        "limit" => 1000,
        "available" => true
      )
    end

    it "caps auto-balanced weights at the runner maximum" do
      high = build_api_runner(key: "opencode", budget: 20_000, weight: 1)
      low = build_api_runner(key: "kilocode", budget: 20, weight: 1)

      described_class.call(user: user)

      expect(high.reload.weight).to eq(Runner::MAX_WEIGHT)
      expect(low.reload.weight).to eq(1)
    end

    it "leaves runners without a monthly budget unchanged and marks them unavailable" do
      runner = create(
        :runner,
        user: user,
        runner_key: "opencode",
        auth_type: "api_key",
        provider_api_key: api_key,
        weight: 7,
        config: { "opencode" => { "api_provider" => "openrouter", "model" => model_id } }
      )

      described_class.call(user: user)

      expect(runner.reload.weight).to eq(7)
      expect(user.runner_states.find_by!(runner_name: runner.routing_key).quota_status_snapshot).to include(
        "available" => false,
        "source" => "monthly_budget_missing"
      )
    end

    it "uses provider check_quota for subscription runners when available" do
      provider_name = RunnerSupport.harness_runner_key_for("claude").to_sym
      status = Struct.new(:remaining, :limit, :reset_at, :unit) do
        def available? = true
      end.new(400, 800, 1.hour.from_now, "requests")
      provider = double(subscription_unset_vars: [], check_quota: status)

      allow(AgentHarness).to receive(:provider).with(provider_name).and_return(provider)

      described_class.call(user: user)

      expect(provider).to have_received(:check_quota).with(env: {})
      expect(user.runner_states.find_by!(runner_name: "claude").quota_status_snapshot).to include(
        "remaining" => 400,
        "limit" => 800,
        "available" => true,
        "unit" => "requests",
        "source" => "provider"
      )
    end
  end
end
