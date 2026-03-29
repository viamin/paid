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

    it "includes copilot" do
      expect(described_class::CONTAINER_EXECUTABLE_PROVIDER_KEYS).to include("copilot")
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

    it "includes copilot when backed by the agent harness registry" do
      keys = described_class.container_executable_provider_keys
      expect(keys).to include("copilot")
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

    it "returns true for copilot" do
      expect(described_class.container_executable_provider_key?("copilot")).to be true
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

  describe ".subscription_auth_unset_vars_for" do
    it "returns the codex unset vars" do
      expect(described_class.subscription_auth_unset_vars_for("codex")).to include("OPENAI_API_KEY")
    end

    it "returns the gemini unset vars" do
      expect(described_class.subscription_auth_unset_vars_for("gemini")).to include("GEMINI_API_KEY")
    end

    it "returns an empty array for unknown providers" do
      expect(described_class.subscription_auth_unset_vars_for("unknown_provider")).to eq([])
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

    it "returns false when login matches a different provider" do
      expect(described_class.provider_bot_username_for?("claude", "copilot[bot]")).to be false
    end

    it "returns false for an unknown provider" do
      expect(described_class.provider_bot_username_for?("unknown", "claude[bot]")).to be false
    end
  end
end
