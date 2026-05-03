# frozen_string_literal: true

require "rails_helper"

RSpec.describe Providers::HarnessExecutionPlan do
  describe ".call" do
    it "builds the OpenCode execution contract through agent-harness" do
      user = create(:user)
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
        "OPENAI_API_KEY" => "sk-openrouter-secret",
        "OPENAI_BASE_URL" => "https://openrouter.ai/api/v1"
      )
    end

    it "writes opencode.json with provider as record, not string" do
      user = create(:user)
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
      expect(parsed["model"]).to eq("moonshotai/kimi-k2-0905")
      expect(parsed).not_to have_key("baseURL")
    end

    it "constructs the harness provider with external sandboxing enabled" do
      provider = instance_double(Provider, provider_key: "claude", agent_harness_provider_runtime: nil)
      harness_provider = double(plan_execution: { command: %w[claude ping], env: {}, preparation: nil })
      provider_class = Class.new do
        def self.new(config:)
          raise "stub me"
        end
      end

      expect(AgentHarness::Providers::Registry.instance).to receive(:get).with(:claude).and_return(provider_class)
      expect(provider_class).to receive(:new) do |config:|
        expect(config).to be_a(AgentHarness::ProviderConfig)
        expect(config.name).to eq(:claude)
        expect(config.externally_sandboxed).to be(true)
        harness_provider
      end

      described_class.call(provider: provider, prompt: "ping")
    end
  end
end
