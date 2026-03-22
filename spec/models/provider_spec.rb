# frozen_string_literal: true

require "rails_helper"

RSpec.describe Provider do
  describe "associations" do
    it { is_expected.to belong_to(:user) }
  end

  describe "validations" do
    subject(:provider) { build(:provider) }

    it { is_expected.to validate_presence_of(:provider_key) }
    it { is_expected.to validate_uniqueness_of(:provider_key).scoped_to(:user_id) }

    it "validates provider_key against agent harness-supported providers" do
      expect(provider).to allow_value("cursor").for(:provider_key)
      expect(provider).to allow_value("gemini").for(:provider_key)
      expect(provider).not_to allow_value("unknown_provider").for(:provider_key)
    end
  end

  describe ".supported_provider_keys" do
    it "returns app provider keys backed by the agent harness registry" do
      expect(described_class.supported_provider_keys).to include("claude", "cursor", "gemini", "codex", "kilocode", "copilot")
      expect(described_class.supported_provider_keys).not_to include("github_copilot")
    end
  end

  describe ".addable_provider_keys" do
    it "returns only providers installed in paid-agent" do
      expect(described_class.addable_provider_keys).to eq([ "claude" ])
    end
  end

  describe ".harness_provider_key_for" do
    it "maps app provider keys to agent harness provider keys" do
      expect(described_class.harness_provider_key_for("copilot")).to eq("github_copilot")
      expect(described_class.harness_provider_key_for("gemini")).to eq("gemini")
    end
  end

  describe ".agent_type_for" do
    it "maps provider keys to app agent types" do
      expect(described_class.agent_type_for("claude")).to eq("claude_code")
      expect(described_class.agent_type_for("copilot")).to eq("copilot")
    end
  end

  describe ".provider_key_for_agent_type" do
    it "maps app agent types back to provider keys" do
      expect(described_class.provider_key_for_agent_type("claude_code")).to eq("claude")
      expect(described_class.provider_key_for_agent_type("copilot")).to eq("copilot")
    end
  end

  describe ".ensure_default_for" do
    let(:user) { create(:user) }

    it "creates the default provider when missing" do
      user.providers.delete_all

      expect { described_class.ensure_default_for(user) }
        .to change { user.providers.where(provider_key: "claude").count }
        .from(0).to(1)
    end

    it "is idempotent" do
      expect { described_class.ensure_default_for(user) }
        .not_to change { user.providers.where(provider_key: "claude").count }
    end
  end

  describe ".display_name" do
    it "uses agent harness provider display names when available" do
      expect(described_class.display_name("codex")).to eq("OpenAI Codex CLI")
      expect(described_class.display_name("copilot")).to eq("GitHub Copilot CLI")
    end

    it "falls back to titleized keys for unknown providers" do
      expect(described_class.display_name("unknown_provider")).to eq("Unknown Provider")
    end
  end

  describe "agent-run provider guardrails" do
    let(:user) { create(:user) }

    it "prevents disabling the last provider enabled for agent runs" do
      provider = user.providers.find_by!(provider_key: "claude")

      expect(provider.update(enabled_for_agent_runs: false)).to be(false)
      expect(provider.errors[:enabled_for_agent_runs]).to include("must keep at least one provider enabled for agent runs")
    end

    it "does not allow disabling the default provider even when another provider is enabled" do
      user.providers.create!(provider_key: "cursor")
      default_key = described_class.default_provider_key
      provider = user.providers.find_by!(provider_key: default_key)

      expect(provider.update(enabled_for_agent_runs: false)).to be(false)
      expect(provider.errors[:enabled_for_agent_runs]).to include(
        "#{described_class.display_name(default_key)} must remain enabled for agent runs"
      )
    end

    it "allows disabling a non-default provider when the default remains enabled" do
      provider = user.providers.create!(provider_key: "cursor")

      expect(provider.update(enabled_for_agent_runs: false)).to be(true)
    end
  end
end
