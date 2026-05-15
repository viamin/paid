# frozen_string_literal: true

require "rails_helper"
require "securerandom"

RSpec.describe Providers::HarnessExecutionPlan do
  describe ".for_provider_key" do
    let(:copilot_plan_payload) do
      {
        command: %w[copilot --autopilot --max-autopilot-continues 50 --output-format json -p ping],
        env: { "COPILOT_ALLOW_ALL" => "true" },
        preparation: nil
      }
    end

    let(:harness_provider) do
      instance_double(AgentHarness::Providers::GithubCopilot, plan_execution: copilot_plan_payload)
    end

    let(:provider_class) { class_double(AgentHarness::Providers::GithubCopilot) }

    before do
      allow(AgentHarness).to receive(:provider_class).with(:github_copilot).and_return(provider_class)
      allow(AgentHarness).to receive(:build_config).with(:github_copilot).and_return(
        AgentHarness::ProviderConfig.new(:github_copilot)
      )
      allow(provider_class).to receive(:new).with(config: kind_of(AgentHarness::ProviderConfig)).and_return(harness_provider)
    end

    it "uses plan_execution for probe-dependent providers" do
      plan = described_class.for_provider_key(
        provider_key: "copilot",
        prompt: "ping",
        options: { dangerous_mode: true }
      )

      expect(harness_provider).to have_received(:plan_execution).with(prompt: "ping", dangerous_mode: true)
      expect(plan.command).to eq(%w[copilot --autopilot --max-autopilot-continues 50 --output-format json -p ping])
      expect(plan.env).to include("COPILOT_ALLOW_ALL" => "true")
    end
  end

  describe ".call" do
    it "builds the OpenCode execution contract through agent-harness" do
      user = create(
        :user,
        email: "harness-execution-plan-#{SecureRandom.hex(6)}@example.com",
        account: create(:account, slug: "harness-execution-plan-#{SecureRandom.hex(6)}")
      )
      api_key = create(:provider_api_key, user: user, api_service_type: "openrouter", api_key: "sk-openrouter-secret")
      provider = create(
        :provider,
        user: user,
        provider_key: "opencode",
        auth_type: "api_key",
        provider_api_key: api_key,
        config: { "opencode" => { "api_provider" => "openrouter", "model" => "moonshotai/kimi-k2-0905" } }
      )

      plan = described_class.call(provider: provider, prompt: "ping")

      expect(plan.command).to eq(%w[opencode run ping])
      expect(plan.env).to include(
        "OPENROUTER_API_KEY" => "sk-openrouter-secret",
        "OPENAI_BASE_URL" => "https://openrouter.ai/api/v1"
      )
    end

    it "writes opencode.json with provider as record, not string" do
      user = create(
        :user,
        email: "harness-execution-plan-#{SecureRandom.hex(6)}@example.com",
        account: create(:account, slug: "harness-execution-plan-#{SecureRandom.hex(6)}")
      )
      api_key = create(:provider_api_key, user: user, api_service_type: "openrouter", api_key: "sk-openrouter-secret")
      provider = create(
        :provider,
        user: user,
        provider_key: "opencode",
        auth_type: "api_key",
        provider_api_key: api_key,
        config: { "opencode" => { "api_provider" => "openrouter", "model" => "moonshotai/kimi-k2-0905" } }
      )

      plan = described_class.call(provider: provider, prompt: "ping")

      expect(plan.preparation.file_writes.first.path).to eq("~/.config/opencode/opencode.json")
      parsed = JSON.parse(plan.preparation.file_writes.first.content)
      expect(parsed["provider"]).to eq({ "openrouter" => {} })
      expect(parsed["model"]).to eq("openrouter/moonshotai/kimi-k2-0905")
      expect(parsed).not_to have_key("baseURL")
    end

    it "constructs the harness provider with external sandboxing enabled" do
      provider = instance_double(Provider, provider_key: "claude", agent_harness_provider_runtime: nil)
      harness_provider = instance_double(
        AgentHarness::Providers::Anthropic,
        plan_execution: { command: %w[claude ping], env: {}, preparation: nil }
      )
      provider_class = class_double(AgentHarness::Providers::Anthropic)

      allow(AgentHarness).to receive(:provider_class).with(:claude).and_return(provider_class)
      allow(AgentHarness).to receive(:build_config).with(:claude).and_return(
        AgentHarness::ProviderConfig.new(:claude)
      )

      allow(provider_class).to receive(:new) do |config:|
        expect(config).to be_a(AgentHarness::ProviderConfig)
        expect(config.name).to eq(:claude)
        expect(config.externally_sandboxed).to be(true)
        harness_provider
      end

      described_class.call(provider: provider, prompt: "ping")
    end
  end
end
