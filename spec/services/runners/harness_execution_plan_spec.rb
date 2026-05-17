# frozen_string_literal: true

require "rails_helper"
require "securerandom"

RSpec.describe Runners::HarnessExecutionPlan do
  def build_user_with_account
    create(
      :user,
      email: "harness-execution-plan-#{SecureRandom.hex(6)}@example.com",
      account: create(:account, slug: "harness-execution-plan-#{SecureRandom.hex(6)}")
    )
  end

  describe ".for_runner_key" do
    let(:copilot_plan_payload) do
      {
        command: %w[copilot --autopilot --max-autopilot-continues 50 --output-format json -p ping],
        env: { "COPILOT_ALLOW_ALL" => "true" },
        preparation: nil
      }
    end

    let(:harness_runner) do
      instance_double(AgentHarness::Runners::GithubCopilot, plan_execution: copilot_plan_payload)
    end

    let(:runner_class) { class_double(AgentHarness::Runners::GithubCopilot) }

    before do
      allow(AgentHarness).to receive(:runner_class).with(:github_copilot).and_return(runner_class)
      allow(AgentHarness).to receive(:build_config).with(:github_copilot).and_return(
        AgentHarness::ProviderConfig.new(:github_copilot)
      )
      allow(runner_class).to receive(:new).with(config: kind_of(AgentHarness::ProviderConfig)).and_return(harness_runner)
    end

    it "uses plan_execution for probe-dependent providers" do
      plan = described_class.for_runner_key(
        runner_key: "copilot",
        prompt: "ping",
        options: { dangerous_mode: true }
      )

      expect(harness_runner).to have_received(:plan_execution).with(prompt: "ping", dangerous_mode: true)
      expect(plan.command).to eq(%w[copilot --autopilot --max-autopilot-continues 50 --output-format json -p ping])
      expect(plan.env).to include("COPILOT_ALLOW_ALL" => "true")
    end
  end

  describe ".call" do
    it "builds the OpenCode execution contract through agent-harness" do
      user = build_user_with_account
      api_key = create(:provider_api_key, user: user, api_service_type: "openrouter", api_key: "sk-openrouter-secret")
      runner = create(
        :runner,
        user: user,
        runner_key: "opencode",
        auth_type: "api_key",
        provider_api_key: api_key,
        config: { "opencode" => { "api_provider" => "openrouter", "model" => "moonshotai/kimi-k2-0905" } }
      )

      plan = described_class.call(runner: runner, prompt: "ping")

      expect(plan.command).to eq(%w[opencode run ping])
      expect(plan.env).to include(
        "OPENROUTER_API_KEY" => "sk-openrouter-secret",
        "OPENAI_BASE_URL" => "https://openrouter.ai/api/v1"
      )
    end

    it "writes opencode.json with runner as record, not string" do
      user = build_user_with_account
      api_key = create(:provider_api_key, user: user, api_service_type: "openrouter", api_key: "sk-openrouter-secret")
      runner = create(
        :runner,
        user: user,
        runner_key: "opencode",
        auth_type: "api_key",
        provider_api_key: api_key,
        config: { "opencode" => { "api_provider" => "openrouter", "model" => "moonshotai/kimi-k2-0905" } }
      )

      plan = described_class.call(runner: runner, prompt: "ping")

      expect(plan.preparation.file_writes.first.path).to eq("~/.config/opencode/opencode.json")
      parsed = JSON.parse(plan.preparation.file_writes.first.content)
      expect(parsed["provider"]).to eq({ "openrouter" => {} })
      expect(parsed["model"]).to eq("openrouter/moonshotai/kimi-k2-0905")
      expect(parsed).not_to have_key("baseURL")
    end

    it "writes Pi auth.json for API-key runners so request-scoped credentials win" do
      user = build_user_with_account
      api_key = create(:provider_api_key, user: user, api_service_type: "deepseek", api_key: "sk-deepseek-secret")
      runner = create(
        :runner,
        user: user,
        runner_key: "pi",
        auth_type: "api_key",
        provider_api_key: api_key,
        config: { "pi" => { "api_provider" => "deepseek", "model" => "deepseek-chat" } }
      )

      plan = described_class.call(runner: runner, prompt: "ping")

      expect(plan.command).to include("pi", "--provider", "deepseek", "--model", "deepseek-chat")
      expect(plan.preparation.file_writes.first.path).to eq("/home/agent/.pi/agent/auth.json")
      expect(plan.preparation.file_writes.first.mode).to eq(0o600)
      expect(JSON.parse(plan.preparation.file_writes.first.content)).to eq(
        "deepseek" => {
          "type" => "api_key",
          "key" => "sk-deepseek-secret"
        }
      )
    end

    it "constructs the harness runner with external sandboxing enabled" do
      runner = instance_double(Runner, runner_key: "claude", agent_harness_runner_runtime: nil)
      harness_runner = instance_double(
        AgentHarness::Runners::Anthropic,
        plan_execution: { command: %w[claude ping], env: {}, preparation: nil }
      )
      runner_class = class_double(AgentHarness::Runners::Anthropic)

      allow(AgentHarness).to receive(:runner_class).with(:claude).and_return(runner_class)
      allow(AgentHarness).to receive(:build_config).with(:claude).and_return(
        AgentHarness::ProviderConfig.new(:claude)
      )

      allow(runner_class).to receive(:new) do |config:|
        expect(config).to be_a(AgentHarness::ProviderConfig)
        expect(config.name).to eq(:claude)
        expect(config.externally_sandboxed).to be(true)
        harness_runner
      end

      described_class.call(runner: runner, prompt: "ping")
    end
  end
end
