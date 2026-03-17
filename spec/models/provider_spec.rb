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
    it "returns built-in provider keys from the agent harness registry" do
      expect(described_class.supported_provider_keys).to include("claude", "cursor", "gemini", "codex", "kilocode")
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
      expect(described_class.display_name("github_copilot")).to eq("GitHub Copilot CLI")
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

    it "does not allow disabling claude even when another provider is enabled" do
      user.providers.create!(provider_key: "cursor")
      provider = user.providers.find_by!(provider_key: "claude")

      expect(provider.update(enabled_for_agent_runs: false)).to be(false)
      expect(provider.errors[:enabled_for_agent_runs]).to include("Claude must remain enabled for agent runs")
    end

    it "allows disabling a non-claude provider when claude remains enabled" do
      provider = user.providers.create!(provider_key: "cursor")

      expect(provider.update(enabled_for_agent_runs: false)).to be(true)
    end
  end
end
