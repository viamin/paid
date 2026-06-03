# frozen_string_literal: true

require "rails_helper"
require "securerandom"

RSpec.describe Runners::HarnessExecutionPlan do
  describe ".for_runner_key", :no_db do
    let(:copilot_plan_payload) do
      {
        command: %w[copilot --autopilot --max-autopilot-continues 50 --output-format json -p ping],
        env: { "COPILOT_ALLOW_ALL" => "true" },
        preparation: nil
      }
    end

    let(:harness_runner) do
      instance_double(AgentHarness::Providers::GithubCopilot, plan_execution: copilot_plan_payload)
    end

    let(:provider_class) { class_double(AgentHarness::Providers::GithubCopilot) }

    before do
      allow(AgentHarness).to receive(:provider_class).with(:github_copilot).and_return(provider_class)
      allow(AgentHarness).to receive(:build_config).with(:github_copilot).and_return(
        AgentHarness::ProviderConfig.new(:github_copilot)
      )
      allow(provider_class).to receive(:new).with(config: kind_of(AgentHarness::ProviderConfig)).and_return(harness_runner)
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

    it "keeps the prompt positional when Claude tools are disabled" do
      allow(AgentHarness).to receive(:provider_class).and_call_original
      allow(AgentHarness).to receive(:build_config).and_call_original

      plan = described_class.for_runner_key(
        runner_key: "claude",
        prompt: "Say hello",
        options: { tools: :none }
      )

      disallowed_tools_flag = plan.command.find { |part| part.start_with?("--disallowedTools=") }

      expect(disallowed_tools_flag).to start_with("--disallowedTools=Agent,Bash,")
      expect(plan.command).not_to include("--disallowedTools")
      expect(plan.command.last).to eq("Say hello")
    end

    it "passes an explicit empty MCP config to Claude when none are configured" do
      allow(AgentHarness).to receive(:provider_class).and_call_original
      allow(AgentHarness).to receive(:build_config).and_call_original

      plan = described_class.for_runner_key(
        runner_key: "claude",
        prompt: "Say hello"
      )

      # claude's --mcp-config is variadic, so the flag must use the --flag=value
      # form to avoid swallowing the trailing positional prompt.
      mcp_flag = plan.command.find { |part| part.start_with?("--mcp-config=") }

      expect(mcp_flag).to be_present
      expect(plan.command).not_to include("--mcp-config")
      expect(plan.command.last).to eq("Say hello")
    end

    # Regression guard for the variadic --mcp-config bug (viamin/agent-harness#229,
    # cleanup tracked in #2435). The Claude CLI treats `--mcp-config <configs...>`
    # as variadic, so a bare "--mcp-config" token immediately before the positional
    # prompt makes the CLI swallow the prompt as a second config path. The flag must
    # always be the single-token --flag=value form, for both the empty-server and
    # configured-server paths. A structural assertion (rather than running the CLI)
    # is enough: the bug is purely about argv shape.
    [
      [ "empty server list", {} ],
      [ "configured stdio server",
        { mcp_servers: [ { name: "fs", transport: "stdio", command: "x", args: [ "/ws" ] } ] } ]
    ].each do |label, options|
      it "never emits a bare --mcp-config token before the prompt (#{label})" do
        allow(AgentHarness).to receive(:provider_class).and_call_original
        allow(AgentHarness).to receive(:build_config).and_call_original

        plan = described_class.for_runner_key(runner_key: "claude", prompt: "the prompt", options: options)

        expect(plan.command).not_to include("--mcp-config"), "found space-form --mcp-config that swallows the prompt: #{plan.command.inspect}"
        expect(plan.command.count { |part| part.to_s.start_with?("--mcp-config=") }).to eq(1)
        expect(plan.command.last).to eq("the prompt")
      end
    end
  end

  describe ".call" do
    let(:runner_double_class) do
      Class.new do
        def runner_key; end

        def agent_harness_runner_runtime; end
      end
    end

    it "builds the OpenCode execution contract through agent-harness" do
      user = create(
        :user,
        email: "harness-execution-plan-#{SecureRandom.hex(6)}@example.com",
        account: create(:account, slug: "harness-execution-plan-#{SecureRandom.hex(6)}")
      )
      api_key = create(:runner_api_key, user: user, api_service_type: "openrouter", api_key: "sk-openrouter-secret")
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
      user = create(
        :user,
        email: "harness-execution-plan-#{SecureRandom.hex(6)}@example.com",
        account: create(:account, slug: "harness-execution-plan-#{SecureRandom.hex(6)}")
      )
      api_key = create(:runner_api_key, user: user, api_service_type: "openrouter", api_key: "sk-openrouter-secret")
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
      expect(parsed).not_to have_key("provider")
      expect(parsed["model"]).to eq("openrouter/moonshotai/kimi-k2-0905")
      expect(parsed).not_to have_key("baseURL")
    end

    it "constructs the harness runner with external sandboxing enabled", :no_db do
      runner = instance_double(runner_double_class, runner_key: "claude", agent_harness_runner_runtime: nil)
      harness_runner = instance_double(
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
        harness_runner
      end

      described_class.call(runner: runner, prompt: "ping")
    end
  end
end
