# frozen_string_literal: true

require "rails_helper"
require "set"

RSpec.describe ProviderSupport do
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

    it "excludes copilot because the CLI is not an agent runner" do
      expect(described_class::CONTAINER_EXECUTABLE_PROVIDER_KEYS).not_to include("copilot")
    end

    it "includes aider" do
      expect(described_class::CONTAINER_EXECUTABLE_PROVIDER_KEYS).to include("aider")
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

    it "excludes copilot even when backed by the agent harness registry" do
      keys = described_class.container_executable_provider_keys
      expect(keys).not_to include("copilot")
    end

    it "includes aider when backed by the agent harness registry" do
      keys = described_class.container_executable_provider_keys
      expect(keys).to include("aider")
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

    it "returns false for copilot" do
      expect(described_class.container_executable_provider_key?("copilot")).to be false
    end

    it "returns true for aider" do
      expect(described_class.container_executable_provider_key?("aider")).to be true
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
    end

    it "titleizes unknown types" do
      expect(described_class.api_service_type_label("unknown")).to eq("Unknown")
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
end
