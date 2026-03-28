# frozen_string_literal: true

require "rails_helper"

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

    it "includes opencode" do
      expect(described_class::CONTAINER_EXECUTABLE_PROVIDER_KEYS).to include("opencode")
    end
  end

  describe ".container_executable_provider_keys" do
    it "includes codex when backed by the agent harness registry" do
      keys = described_class.container_executable_provider_keys
      expect(keys).to include("claude")
      expect(keys).to include("codex")
    end

    it "includes kilocode when backed by the agent harness registry" do
      keys = described_class.container_executable_provider_keys
      expect(keys).to include("kilocode")
    end

    it "includes opencode when backed by the agent harness registry" do
      keys = described_class.container_executable_provider_keys
      expect(keys).to include("opencode")
    end
  end

  describe ".container_executable_provider_key?" do
    it "returns true for codex" do
      expect(described_class.container_executable_provider_key?("codex")).to be true
    end

    it "returns true for claude" do
      expect(described_class.container_executable_provider_key?("claude")).to be true
    end

    it "returns true for kilocode" do
      expect(described_class.container_executable_provider_key?("kilocode")).to be true
    end

    it "returns true for opencode" do
      expect(described_class.container_executable_provider_key?("opencode")).to be true
    end

    it "returns false for non-executable providers" do
      expect(described_class.container_executable_provider_key?("cursor")).to be false
    end
  end

  describe ".subscription_auth_unset_vars_for" do
    it "returns the codex unset vars" do
      expect(described_class.subscription_auth_unset_vars_for("codex")).to include("OPENAI_API_KEY")
    end

    it "returns the gemini unset vars" do
      expect(described_class.subscription_auth_unset_vars_for("gemini")).to include("GEMINI_API_KEY")
    end
  end
end
