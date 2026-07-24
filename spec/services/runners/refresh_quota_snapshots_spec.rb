# frozen_string_literal: true

require "rails_helper"

RSpec.describe Runners::RefreshQuotaSnapshots do
  describe ".call" do
    let(:user) { create(:user) }
    let(:model_id) { "moonshotai/kimi-k2-0905" }
    let(:api_key) { create(:provider_api_key, user: user, api_service_type: "openrouter") }

    def build_api_runner(key:, budget: nil, weight: 1)
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

    it "persists quota snapshot for API-key runners with a monthly budget" do
      runner = build_api_runner(key: "opencode", budget: 1_000)
      project = create(:project, account: user.account, created_by: user)
      agent_run = create(:agent_run, runner: runner, project: project)
      create(:token_usage, agent_run: agent_run, input_tokens: 300, output_tokens: 0)

      described_class.call(user: user)

      snapshot = user.runner_states.find_by!(runner_name: runner.routing_key).quota_status_snapshot
      expect(snapshot).to include(
        "remaining" => 700,
        "limit" => 1000,
        "available" => true,
        "source" => "monthly_token_budget"
      )
    end

    it "marks runners without a monthly budget as unavailable" do
      runner = build_api_runner(key: "opencode")

      described_class.call(user: user)

      snapshot = user.runner_states.find_by!(runner_name: runner.routing_key).quota_status_snapshot
      expect(snapshot).to include(
        "available" => false,
        "source" => "monthly_budget_missing"
      )
    end

    it "does NOT modify runner weights (unlike QuotaBalanceService)" do
      runner = build_api_runner(key: "opencode", budget: 1_000, weight: 5)

      described_class.call(user: user)

      expect(runner.reload.weight).to eq(5)
    end

    it "uses provider check_quota for subscription runners when available" do
      provider_name = RunnerSupport.harness_runner_key_for("claude").to_sym
      status = Struct.new(:remaining, :limit, :reset_at, :unit) do
        def available? = true
      end.new(600, 1000, 1.hour.from_now, "requests")
      provider = double(subscription_unset_vars: [], check_quota: status)

      allow(AgentHarness).to receive(:provider).with(provider_name).and_return(provider)

      described_class.call(user: user)

      expect(provider).to have_received(:check_quota).with(env: {})
      snapshot = user.runner_states.find_by!(runner_name: "claude").quota_status_snapshot
      expect(snapshot).to include(
        "remaining" => 600,
        "limit" => 1000,
        "available" => true,
        "source" => "provider"
      )
    end

    it "skips subscription runners whose provider does not implement check_quota" do
      provider_name = RunnerSupport.harness_runner_key_for("claude").to_sym
      provider = double(subscription_unset_vars: [])
      allow(AgentHarness).to receive(:provider).with(provider_name).and_return(provider)

      expect { described_class.call(user: user) }.not_to raise_error
    end

    it "continues processing other runners when one provider raises an error" do
      good_runner = build_api_runner(key: "opencode", budget: 500)

      # Stub the claude provider to raise so the subscription runner fails
      provider_name = RunnerSupport.harness_runner_key_for("claude").to_sym
      allow(AgentHarness).to receive(:provider).with(provider_name).and_raise("provider unavailable")

      expect { described_class.call(user: user) }.not_to raise_error

      # The API-key runner should still have been processed
      good_snapshot = user.runner_states.find_by(runner_name: good_runner.routing_key)&.quota_status_snapshot
      expect(good_snapshot).to include("available" => true)
    end
  end
end
