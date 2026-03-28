# frozen_string_literal: true

require "rails_helper"

RSpec.describe Provider do
  describe "associations" do
    it { is_expected.to belong_to(:user) }
    it { is_expected.to belong_to(:provider_api_key).optional }
  end

  describe "validations" do
    subject(:provider) { build(:provider) }

    it { is_expected.to validate_presence_of(:provider_key) }
    it { is_expected.to validate_presence_of(:auth_type) }
    it { is_expected.to validate_presence_of(:fallback_role) }

    it "validates provider_key against agent harness-supported providers" do
      expect(provider).to allow_value("cursor").for(:provider_key)
      expect(provider).to allow_value("gemini").for(:provider_key)
      expect(provider).not_to allow_value("unknown_provider").for(:provider_key)
    end

    it "validates auth_type inclusion" do
      expect(provider).to allow_value("subscription").for(:auth_type)
      expect(provider).not_to allow_value("free_trial").for(:auth_type)
    end

    it "allows api_key auth_type with a valid provider_api_key" do
      api_key = create(:provider_api_key, user: provider.user, compatible_providers: %w[cursor])
      provider.provider_api_key = api_key
      expect(provider).to allow_value("api_key").for(:auth_type)
    end

    it "validates fallback_role inclusion" do
      expect(provider).to allow_value("standard").for(:fallback_role)
      expect(provider).not_to allow_value("primary").for(:fallback_role)
    end

    it "allows rate_limit_fallback role on api_key providers" do
      api_key = create(:provider_api_key, user: provider.user, compatible_providers: %w[cursor])
      provider.auth_type = "api_key"
      provider.provider_api_key = api_key
      expect(provider).to allow_value("rate_limit_fallback").for(:fallback_role)
    end

    it "requires standard fallback_role for subscription providers" do
      provider.auth_type = "subscription"
      provider.fallback_role = "rate_limit_fallback"

      expect(provider).not_to be_valid
      expect(provider.errors[:fallback_role]).to include("must be standard for subscription providers")
    end

    it "requires provider_api_key for api_key auth type" do
      provider.auth_type = "api_key"
      provider.provider_api_key = nil

      expect(provider).not_to be_valid
      expect(provider.errors[:provider_api_key]).to include("is required for API key authentication")
    end

    it "rejects a non-existent provider_api_key_id for api_key auth type" do
      provider.auth_type = "api_key"
      provider.provider_api_key_id = -1

      expect(provider).not_to be_valid
      expect(provider.errors[:provider_api_key]).to include("is required for API key authentication")
    end

    it "rejects provider_api_key for subscription auth type" do
      api_key = create(:provider_api_key, user: provider.user)
      provider.auth_type = "subscription"
      provider.provider_api_key = api_key

      expect(provider).not_to be_valid
      expect(provider.errors[:provider_api_key]).to include("must not be set for subscription authentication")
    end

    it "prevents duplicate subscription entries for the same user and provider_key" do
      create(:provider, user: provider.user, provider_key: "cursor", auth_type: "subscription")
      duplicate = build(:provider, user: provider.user, provider_key: "cursor", auth_type: "subscription")

      expect(duplicate).not_to be_valid
      expect(duplicate.errors[:provider_key]).to include("already has a subscription entry")
    end

    it "prevents duplicate api_key entries for the same user, provider_key, and api key" do
      api_key = create(:provider_api_key, user: provider.user, compatible_providers: %w[cursor])
      create(:provider, user: provider.user, provider_key: "cursor", auth_type: "api_key", provider_api_key: api_key)
      duplicate = build(:provider, user: provider.user, provider_key: "cursor", auth_type: "api_key", provider_api_key: api_key)

      expect(duplicate).not_to be_valid
      expect(duplicate.errors[:provider_key]).to include("already has an entry with this API key")
    end

    it "rejects provider_api_key belonging to a different user" do
      other_user = create(:user)
      api_key = create(:provider_api_key, user: other_user, compatible_providers: %w[cursor])
      provider.auth_type = "api_key"
      provider.provider_api_key = api_key
      provider.provider_key = "cursor"

      expect(provider).not_to be_valid
      expect(provider.errors[:provider_api_key]).to include("must belong to the same user")
    end

    it "validates API key compatibility with provider_key" do
      api_key = create(:provider_api_key, user: provider.user, compatible_providers: %w[gemini])
      provider.auth_type = "api_key"
      provider.provider_api_key = api_key
      provider.provider_key = "cursor"

      expect(provider).not_to be_valid
      expect(provider.errors[:provider_api_key]).to include("is not compatible with cursor")
    end
  end

  describe "scopes" do
    let(:user) { create(:user) }

    it ".subscription returns only subscription providers" do
      sub = user.providers.find_by(provider_key: "claude")
      api_key = create(:provider_api_key, user: user, compatible_providers: %w[claude])
      api = user.providers.create!(provider_key: "claude", auth_type: "api_key", provider_api_key: api_key)

      expect(described_class.subscription).to include(sub)
      expect(described_class.subscription).not_to include(api)
    end

    it ".api_key returns only api_key providers" do
      sub = user.providers.find_by(provider_key: "claude")
      api_key = create(:provider_api_key, user: user, compatible_providers: %w[claude])
      api = user.providers.create!(provider_key: "claude", auth_type: "api_key", provider_api_key: api_key)

      expect(described_class.api_key).to include(api)
      expect(described_class.api_key).not_to include(sub)
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
      expect(described_class.addable_provider_keys).to match_array(ProviderSupport.addable_provider_keys)
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

    it "creates a subscription provider by default" do
      user.providers.delete_all

      described_class.ensure_default_for(user)
      provider = user.providers.find_by(provider_key: "claude")

      expect(provider.auth_type).to eq("subscription")
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

  describe "#display_name" do
    it "uses custom name when set" do
      provider = build(:provider, name: "My Custom Provider")

      expect(provider.display_name).to eq("My Custom Provider")
    end

    it "uses titleized provider_key for subscription" do
      provider = build(:provider, provider_key: "claude", auth_type: "subscription")

      expect(provider.display_name).to eq("Claude")
    end

    it "appends (API Key) for api_key auth type" do
      provider = build(:provider, provider_key: "claude", auth_type: "api_key", name: nil)

      expect(provider.display_name).to eq("Claude (API Key)")
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

  describe "multiple entries per provider_key" do
    let(:user) { create(:user) }

    it "allows both subscription and api_key entries for the same provider_key" do
      api_key = create(:provider_api_key, user: user, compatible_providers: %w[claude])
      api_provider = user.providers.new(
        provider_key: "claude",
        auth_type: "api_key",
        provider_api_key: api_key
      )

      expect(api_provider).to be_valid
      expect(api_provider.save).to be(true)
      expect(user.providers.where(provider_key: "claude").count).to eq(2)
    end

    it "prevents duplicate subscription entries for the same provider_key" do
      duplicate = user.providers.new(provider_key: "claude", auth_type: "subscription")

      expect { duplicate.save!(validate: false) }.to raise_error(ActiveRecord::RecordNotUnique)
    end
  end
end
