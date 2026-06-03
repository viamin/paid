# frozen_string_literal: true

require "rails_helper"
require "set"

RSpec.describe ProviderSupport do
  before do
    described_class.reset_supported_provider_keys!
  end

  after do
    described_class.reset_supported_provider_keys!
  end

  describe "CONTAINER_EXECUTABLE_PROVIDER_KEYS" do
    it "includes claude" do
      expect(described_class::CONTAINER_EXECUTABLE_PROVIDER_KEYS).to include("claude")
    end

    it "includes codex" do
      expect(described_class::CONTAINER_EXECUTABLE_PROVIDER_KEYS).to include("codex")
    end

    it "includes kilocode" do
      expect(described_class::CONTAINER_EXECUTABLE_PROVIDER_KEYS).to include("kilocode")
    end

    it "includes cursor" do
      expect(described_class::CONTAINER_EXECUTABLE_PROVIDER_KEYS).to include("cursor")
    end

    it "includes opencode" do
      expect(described_class::CONTAINER_EXECUTABLE_PROVIDER_KEYS).to include("opencode")
    end

    it "includes copilot with autopilot mode support" do
      expect(described_class::CONTAINER_EXECUTABLE_PROVIDER_KEYS).to include("copilot")
    end

    it "includes aider" do
      expect(described_class::CONTAINER_EXECUTABLE_PROVIDER_KEYS).to include("aider")
    end

    it "includes pi" do
      expect(described_class::CONTAINER_EXECUTABLE_PROVIDER_KEYS).to include("pi")
    end
  end

  describe ".container_executable_provider_keys" do
    it "includes codex when backed by the agent harness registry" do
      keys = described_class.container_executable_provider_keys
      expect(keys).to include("claude")
      expect(keys).to include("codex")
    end

    it "includes cursor when backed by the agent harness registry" do
      keys = described_class.container_executable_provider_keys
      expect(keys).to include("cursor")
    end

    it "includes kilocode when backed by the agent harness registry" do
      keys = described_class.container_executable_provider_keys
      expect(keys).to include("kilocode")
    end

    it "includes opencode when backed by the agent harness registry" do
      keys = described_class.container_executable_provider_keys
      expect(keys).to include("opencode")
    end

    it "includes copilot when backed by the agent harness registry" do
      keys = described_class.container_executable_provider_keys
      expect(keys).to include("copilot")
    end

    it "includes aider when backed by the agent harness registry" do
      keys = described_class.container_executable_provider_keys
      expect(keys).to include("aider")
    end

    it "includes pi when backed by the agent harness registry" do
      keys = described_class.container_executable_provider_keys
      expect(keys).to include("pi")
    end
  end

  describe ".container_executable_provider_key?" do
    it "returns true for codex" do
      expect(described_class.container_executable_provider_key?("codex")).to be true
    end

    it "returns true for claude" do
      expect(described_class.container_executable_provider_key?("claude")).to be true
    end

    it "returns true for cursor" do
      expect(described_class.container_executable_provider_key?("cursor")).to be true
    end

    it "returns true for kilocode" do
      expect(described_class.container_executable_provider_key?("kilocode")).to be true
    end

    it "returns true for opencode" do
      expect(described_class.container_executable_provider_key?("opencode")).to be true
    end

    it "returns true for copilot" do
      expect(described_class.container_executable_provider_key?("copilot")).to be true
    end

    it "returns true for aider" do
      expect(described_class.container_executable_provider_key?("aider")).to be true
    end

    it "returns true for pi" do
      expect(described_class.container_executable_provider_key?("pi")).to be true
    end

    it "returns false for unsupported providers" do
      expect(described_class.container_executable_provider_key?("unknown_provider")).to be false
    end

    it "returns false for supported providers not in the container-executable set" do
      # All current supported providers are container-executable. Stub the set
      # to simulate a provider whose CLI has not yet been installed in the image.
      stub_const("ProviderSupport::CONTAINER_EXECUTABLE_PROVIDER_KEYS", Set.new(%w[claude]))

      expect(described_class.container_executable_provider_key?("codex")).to be false
    end
  end

  describe "API_SERVICE_TYPES" do
    it "includes the expected service types" do
      expect(described_class::API_SERVICE_TYPES).to include(
        "anthropic" => "Anthropic",
        "openai" => "OpenAI",
        "openrouter" => "OpenRouter",
        "google" => "Google AI",
        "minimax" => "MiniMax",
        "zai" => "z.ai",
        "zai_coding" => "z.ai (Coding Plan)"
      )
    end
  end

  describe ".api_service_type_for" do
    it "returns anthropic for claude" do
      expect(described_class.api_service_type_for("claude")).to eq("anthropic")
    end

    it "returns nil for opencode (dynamic, depends on api_provider)" do
      expect(described_class.api_service_type_for("opencode")).to be_nil
    end

    it "returns nil for kilocode (dynamic, depends on api_provider)" do
      expect(described_class.api_service_type_for("kilocode")).to be_nil
    end

    it "returns openai for codex" do
      expect(described_class.api_service_type_for("codex")).to eq("openai")
    end

    it "returns google for gemini" do
      expect(described_class.api_service_type_for("gemini")).to eq("google")
    end

    it "returns nil for unknown providers" do
      expect(described_class.api_service_type_for("unknown")).to be_nil
    end

    it "returns nil for copilot (no compatible API key type)" do
      expect(described_class.api_service_type_for("copilot")).to be_nil
    end
  end

  describe ".api_service_type_label" do
    it "returns the human-readable label for known types" do
      expect(described_class.api_service_type_label("openrouter")).to eq("OpenRouter")
      expect(described_class.api_service_type_label("anthropic")).to eq("Anthropic")
      expect(described_class.api_service_type_label("minimax")).to eq("MiniMax")
    end

    it "titleizes unknown types" do
      expect(described_class.api_service_type_label("unknown")).to eq("Unknown")
    end
  end

  describe ".supported_provider_keys" do
    it "excludes providers not registered in the harness" do
      allow(AgentHarness).to receive(:providers)
        .and_return(AgentHarness.providers - [ :gemini ])

      supported_keys = described_class.supported_provider_keys

      expect(supported_keys).not_to include("gemini")
    end
  end

  describe ".subscription_auth_unset_vars_for" do
    it "returns the codex unset vars" do
      expect(described_class.subscription_auth_unset_vars_for("codex")).to include("OPENAI_API_KEY")
    end

    it "includes codex proxy header vars" do
      vars = described_class.subscription_auth_unset_vars_for("codex")
      expect(vars).to include("OPENAI_HEADER_X_AGENT_RUN_ID", "OPENAI_HEADER_X_PROXY_TOKEN")
    end

    it "returns the gemini unset vars" do
      expect(described_class.subscription_auth_unset_vars_for("gemini")).to include("GEMINI_API_KEY")
    end

    it "returns the Pi subscription unset vars from the harness" do
      vars = described_class.subscription_auth_unset_vars_for("pi")
      # Pi's upstream subscription_unset_vars changed in agent-harness 0.20.0;
      # assert against what the harness actually returns rather than a hardcoded list.
      expected = AgentHarness.provider(:pi).subscription_unset_vars
      expect(vars).to eq(expected)
    end

    it "returns an empty array for unknown providers" do
      expect(described_class.subscription_auth_unset_vars_for("unknown_provider")).to eq([])
    end

    it "raises when a known provider is missing from agent-harness" do
      allow(AgentHarness).to receive(:provider).with(:codex).and_raise(KeyError, "missing codex")

      expect { described_class.subscription_auth_unset_vars_for("codex") }.to raise_error(KeyError, /missing codex/)
    end

    it "raises when a known provider has invalid harness config" do
      allow(AgentHarness).to receive(:provider).with(:gemini).and_raise(AgentHarness::ConfigurationError, "broken gemini")

      expect { described_class.subscription_auth_unset_vars_for("gemini") }
        .to raise_error(AgentHarness::ConfigurationError, /broken gemini/)
    end
  end

  describe ".proxy_health_check_api_key_for" do
    it "returns :openai for codex" do
      expect(described_class.proxy_health_check_api_key_for("codex")).to eq(:openai)
    end

    it "returns :google for gemini" do
      expect(described_class.proxy_health_check_api_key_for("gemini")).to eq(:google)
    end

    it "returns nil for providers without proxy health checks" do
      expect(described_class.proxy_health_check_api_key_for("claude")).to be_nil
    end
  end

  describe ".provider_bot_username?" do
    it "returns true for known copilot bot usernames" do
      expect(described_class.provider_bot_username?("copilot[bot]")).to be true
      expect(described_class.provider_bot_username?("copilot-pull-request-reviewer")).to be true
    end

    it "returns true for known claude bot usernames" do
      expect(described_class.provider_bot_username?("claude[bot]")).to be true
      expect(described_class.provider_bot_username?("claude-code[bot]")).to be true
    end

    it "returns true for known codex bot usernames" do
      expect(described_class.provider_bot_username?("chatgpt-codex-connector")).to be true
      expect(described_class.provider_bot_username?("chatgpt-codex-connector[bot]")).to be true
    end

    it "returns true for known paid_agent bot usernames" do
      expect(described_class.provider_bot_username?("paid-code-reviewer")).to be true
      expect(described_class.provider_bot_username?("paid-code-reviewer[bot]")).to be true
    end

    it "is case-insensitive" do
      expect(described_class.provider_bot_username?("Claude[bot]")).to be true
      expect(described_class.provider_bot_username?("COPILOT")).to be true
    end

    it "returns false for unknown usernames" do
      expect(described_class.provider_bot_username?("random-user")).to be false
    end

    it "returns false for blank input" do
      expect(described_class.provider_bot_username?(nil)).to be false
      expect(described_class.provider_bot_username?("")).to be false
    end
  end

  describe ".provider_bot_username_for?" do
    it "returns true when login matches the specified provider" do
      expect(described_class.provider_bot_username_for?("claude", "claude[bot]")).to be true
    end

    it "returns true for the paid_agent bot login" do
      expect(described_class.provider_bot_username_for?("paid_agent", "paid-code-reviewer[bot]")).to be true
    end

    it "returns false when login matches a different provider" do
      expect(described_class.provider_bot_username_for?("claude", "copilot[bot]")).to be false
    end

    it "returns false for an unknown provider" do
      expect(described_class.provider_bot_username_for?("unknown", "claude[bot]")).to be false
    end
  end

  describe ".provider_key_for_bot_username" do
    it "returns the provider key for any known alias" do
      expect(described_class.provider_key_for_bot_username("chatgpt-codex-connector")).to eq("codex")
      expect(described_class.provider_key_for_bot_username("chatgpt-codex-connector[bot]")).to eq("codex")
    end

    it "returns nil for unknown usernames" do
      expect(described_class.provider_key_for_bot_username("random-user")).to be_nil
    end
  end

  describe ".provider_bot_usernames_for" do
    it "returns all aliases for the provider as lowercase usernames" do
      expect(described_class.provider_bot_usernames_for("codex"))
        .to eq(Set["chatgpt-codex-connector", "chatgpt-codex-connector[bot]"])
    end

    it "returns an empty set for unknown providers" do
      expect(described_class.provider_bot_usernames_for("unknown")).to eq(Set.new)
    end
  end

  describe ".all_bot_usernames" do
    it "returns a set of all known bot usernames" do
      result = described_class.all_bot_usernames
      expect(result).to be_a(Set)
      expect(result).to include("copilot", "copilot[bot]", "copilot-pull-request-reviewer[bot]")
      expect(result).to include("claude[bot]", "claude-code[bot]")
      expect(result).to include("chatgpt-codex-connector", "chatgpt-codex-connector[bot]")
      expect(result).to include("paid-code-reviewer", "paid-code-reviewer[bot]")
    end

    it "returns all lowercase usernames" do
      expect(described_class.all_bot_usernames.map(&:downcase)).to eq(described_class.all_bot_usernames.to_a)
    end
  end

  describe "provider contract smoke checks" do
    describe "CLI binary mapping completeness" do
      it "has a CLI binary mapping for every container-executable provider" do
        cli_binary_for = {
          "aider" => "aider",
          "claude" => "claude",
          "codex" => "codex",
          "copilot" => "copilot",
          "cursor" => "cursor-agent",
          "gemini" => "gemini",
          "kilocode" => "kilo",
          "opencode" => "opencode",
          "pi" => "pi"
        }

        described_class::CONTAINER_EXECUTABLE_PROVIDER_KEYS.each do |key|
          expect(cli_binary_for).to have_key(key),
            "No CLI binary mapping for container-executable provider '#{key}'. " \
            "Add it to this test and to scripts/test-agent-provider-contracts-inner.sh."
        end
      end
    end

    describe "agent-harness registry backing" do
      it "only contains providers backed by the agent-harness registry" do
        described_class::CONTAINER_EXECUTABLE_PROVIDER_KEYS.each do |key|
          harness_key = described_class.harness_provider_key_for(key)
          expect {
            AgentHarness.provider(harness_key.to_sym)
          }.not_to raise_error
        end
      end
    end

    describe "Codex config.toml shape" do
      let(:codex_provider) { AgentHarness.provider(:codex) }
      let(:config_toml) do
        codex_provider.config_file_content(
          model_provider: "paid",
          base_url: "http://localhost:8080/api/proxy/openai",
          env_key: "OPENAI_API_KEY",
          wire_api: "responses"
        )
      end
      let(:notify_line) { Containers::Provision.codex_notify_line }

      it "generates a TOML body with a [chatgpt] section" do
        expect(config_toml).to match(/^\[chatgpt\]/)
      end

      it "includes required keys in the [chatgpt] section" do
        expect(config_toml).to include('model_provider = "paid"')
        expect(config_toml).to include('env_key = "OPENAI_API_KEY"')
      end

      it "produces a notify line shaped as a TOML string-array assignment" do
        expect(notify_line).to match(/\Anotify\s*=\s*\[/)
      end

      it "produces a full config with notify before section header" do
        full_config = "#{notify_line}\n\n#{config_toml}"
        lines = full_config.lines.map(&:strip).reject(&:empty?)
        notify_idx = lines.index { |l| l.start_with?("notify") }
        section_idx = lines.index { |l| l.start_with?("[chatgpt]") }

        expect(notify_idx).not_to be_nil
        expect(section_idx).not_to be_nil
        expect(notify_idx).to be < section_idx
      end

      it "does not contain bare notify without array brackets" do
        expect(notify_line).not_to match(/\Anotify\s*=\s*"/)
        expect(notify_line).not_to match(/\Anotify\s*=\s*'(?!\[)/)
      end
    end

    describe "copilot inclusion" do
      it "is listed in APP_PROVIDER_KEYS as a known provider" do
        expect(described_class::APP_PROVIDER_KEYS).to include("copilot")
      end

      it "is addable as a container-executable provider" do
        expect(described_class.addable_provider_key?("copilot")).to be true
      end
    end

    describe "pi inclusion" do
      it "is listed in APP_PROVIDER_KEYS as a known provider" do
        expect(described_class::APP_PROVIDER_KEYS).to include("pi")
      end

      it "is addable as a container-executable provider" do
        expect(described_class.addable_provider_key?("pi")).to be true
      end
    end
  end

  describe ".command_with_unset_env" do
    it "returns command unchanged when unset_vars is empty" do
      expect(described_class.command_with_unset_env("my_cmd", [])).to eq("my_cmd")
    end

    it "wraps an array command with env -u flags" do
      result = described_class.command_with_unset_env(%w[my_cmd --flag], %w[VAR1 VAR2])
      expect(result).to eq(%w[env -u VAR1 -u VAR2 my_cmd --flag])
    end

    it "wraps a string command with sh -c and env -u flags" do
      result = described_class.command_with_unset_env("my_cmd --flag", %w[VAR1 VAR2])
      expect(result).to eq([ "sh", "-c", "env -u VAR1 -u VAR2 my_cmd --flag" ])
    end
  end

  describe ".rate_limit_reset_at" do
    let(:provider) { instance_double(AgentHarness::Providers::Codex) }

    def stub_parse(reset)
      allow(provider).to receive(:parse_rate_limit_reset).and_return(reset, nil)
    end

    it "returns a near-future parsed reset unchanged" do
      reset = 30.minutes.from_now
      stub_parse(reset)
      expect(described_class.rate_limit_reset_at(provider, "rate limited")).to be_within(1.second).of(reset)
    end

    it "allows a legitimate weekly reset under the ceiling" do
      reset = 6.days.from_now
      stub_parse(reset)
      expect(described_class.rate_limit_reset_at(provider, "resets next week")).to be_within(1.second).of(reset)
    end

    it "rejects an implausibly far-future reset from the upstream parse bug" do
      # Codex "resets Jan 15" mis-parsed ~10 months out benches the provider.
      stub_parse(10.months.from_now)
      result = described_class.rate_limit_reset_at(provider, "resets Jan 15, 5pm (UTC)")
      expect(result).to be_within(1.minute).of(1.hour.from_now)
    end

    it "logs a warning when it clamps an implausible reset" do
      stub_parse(10.months.from_now)
      expect(Rails.logger).to receive(:warn).with(
        hash_including(message: "runner_support.rate_limit_reset_clamped")
      )
      described_class.rate_limit_reset_at(provider, "resets Jan 15, 5pm (UTC)")
    end

    it "does not log when the parsed reset is within the ceiling" do
      stub_parse(2.hours.from_now)
      expect(Rails.logger).not_to receive(:warn)
      described_class.rate_limit_reset_at(provider, "resets soon")
    end

    it "falls back to one hour when the parsed reset is in the past" do
      stub_parse(5.minutes.ago)
      result = described_class.rate_limit_reset_at(provider, "stale reset")
      expect(result).to be_within(1.minute).of(1.hour.from_now)
    end

    it "falls back to one hour when nothing is parseable" do
      allow(provider).to receive(:parse_rate_limit_reset).and_return(nil)
      result = described_class.rate_limit_reset_at(provider, "no reset here")
      expect(result).to be_within(1.minute).of(1.hour.from_now)
    end

    it "falls back to one hour when the provider raises a configuration error" do
      allow(provider).to receive(:parse_rate_limit_reset).and_raise(AgentHarness::ConfigurationError)
      result = described_class.rate_limit_reset_at(provider, "anything")
      expect(result).to be_within(1.minute).of(1.hour.from_now)
    end
  end
end
