# frozen_string_literal: true

require "rails_helper"
require "securerandom"

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

    describe "weight" do
      it "defaults to 1 on new records" do
        expect(provider.weight).to eq(1)
      end

      it "accepts positive integer values up to MAX_WEIGHT" do
        provider.weight = 1
        expect(provider).to be_valid

        provider.weight = described_class::MAX_WEIGHT
        expect(provider).to be_valid
      end

      it "rejects zero or negative weights" do
        provider.weight = 0
        expect(provider).not_to be_valid
        expect(provider.errors[:weight]).to be_present
      end

      it "rejects weights above MAX_WEIGHT" do
        provider.weight = described_class::MAX_WEIGHT + 1
        expect(provider).not_to be_valid
        expect(provider.errors[:weight]).to be_present
      end
    end

    describe "complexity_thresholds" do
      let(:provider) { build(:provider, provider_key: "cursor") }

      it "is valid with the default thresholds" do
        expect(provider).to be_valid
      end

      it "accepts custom integer thresholds" do
        provider.complexity_thresholds = { "low_max" => 2, "mid_max" => 8 }
        expect(provider).to be_valid
      end

      it "rejects unknown threshold keys" do
        provider.complexity_thresholds = { "ultra_max" => 5 }
        expect(provider).not_to be_valid
        expect(provider.errors[:complexity_thresholds].join).to include("unknown key")
      end

      it "rejects non-integer values" do
        provider.complexity_thresholds = { "low_max" => "nope", "mid_max" => 7 }
        expect(provider).not_to be_valid
        expect(provider.errors[:complexity_thresholds].join).to include("integer")
      end

      it "rejects out-of-range values" do
        provider.complexity_thresholds = { "low_max" => 0, "mid_max" => 7 }
        expect(provider).not_to be_valid
        expect(provider.errors[:complexity_thresholds].join).to include("between 1 and 10")
      end

      it "rejects low_max >= mid_max" do
        provider.complexity_thresholds = { "low_max" => 7, "mid_max" => 5 }
        expect(provider).not_to be_valid
        expect(provider.errors[:complexity_thresholds].join).to include("less than mid_max")
      end

      it "rejects a partial low_max that is inconsistent with the default mid_max" do
        provider.complexity_thresholds = { "low_max" => 8 }
        expect(provider).not_to be_valid
        expect(provider.errors[:complexity_thresholds].join).to include("less than mid_max")
      end

      it "rejects a partial mid_max that is inconsistent with the default low_max" do
        provider.complexity_thresholds = { "mid_max" => 2 }
        expect(provider).not_to be_valid
        expect(provider.errors[:complexity_thresholds].join).to include("less than mid_max")
      end

      it "exposes a merged-with-defaults hash via effective_complexity_thresholds" do
        provider.complexity_thresholds = { "low_max" => 4 }
        expect(provider.effective_complexity_thresholds).to eq("low_max" => 4, "mid_max" => 7)
      end
    end

    describe "tier_model_ids" do
      let(:provider) { build(:provider, provider_key: "cursor") }

      it "is valid when blank" do
        provider.tier_model_ids = {}
        expect(provider).to be_valid
      end

      it "rejects unknown tier keys" do
        provider.tier_model_ids = { "ultra" => "x" }
        expect(provider).not_to be_valid
        expect(provider.errors[:tier_model_ids].join).to include("invalid tier")
      end

      it "rejects references to unknown models" do
        provider.tier_model_ids = { "low" => "no-such-model" }
        expect(provider).not_to be_valid
        expect(provider.errors[:tier_model_ids].join).to include("unknown model")
      end

      it "rejects models that belong to a different provider" do
        create(:llm_model, model_id: "gpt-low", provider: "openai", tier: "low")
        provider.tier_model_ids = { "low" => "gpt-low" }
        expect(provider).not_to be_valid
        expect(provider.errors[:tier_model_ids].join).to include("does not belong")
      end

      it "accepts models that belong to the provider" do
        create(:llm_model, model_id: "haiku-y", provider: "anthropic", tier: "low")
        provider.tier_model_ids = { "low" => "haiku-y" }
        expect(provider).to be_valid
      end

      it "rejects tier_model_ids for providers without a tier mapping" do
        unmapped = build(:provider, provider_key: "copilot")
        unmapped.tier_model_ids = { "low" => "anything" }
        expect(unmapped).not_to be_valid
        expect(unmapped.errors[:tier_model_ids].join).to include("not configurable")
      end

      it "allows direct-outbound providers to reference models from any upstream provider" do
        user = create(:user)
        api_key = create(:provider_api_key, user: user, api_service_type: "zai")
        create(:llm_model, model_id: "glm-5.1", provider: "zai", tier: "high")
        provider = build(
          :provider,
          user: user,
          provider_key: "kilocode",
          auth_type: "api_key",
          provider_api_key: api_key,
          config: { "kilocode" => { "api_provider" => "zai", "model" => "glm-5.1" } },
          tier_model_ids: { "high" => "glm-5.1", "mid" => "glm-5.1", "low" => "glm-5.1" }
        )

        expect(provider).to be_valid
      end

      it "rejects partial tier_model_ids for direct-outbound providers" do
        user = create(:user)
        api_key = create(:provider_api_key, user: user, api_service_type: "zai")
        create(:llm_model, model_id: "glm-5.1", provider: "zai", tier: "high")
        provider = create(
          :provider,
          user: user,
          provider_key: "kilocode",
          auth_type: "api_key",
          provider_api_key: api_key,
          config: { "kilocode" => { "api_provider" => "zai", "model" => "glm-5.1" } }
        )

        provider.tier_model_ids = { "high" => "glm-5.1" }
        expect(provider).not_to be_valid
        expect(provider.errors[:tier_model_ids].join).to include("must map all tiers")
      end

      it "rejects crafted tier_model_ids that pin a direct-outbound provider to a different model" do
        user = create(:user)
        api_key = create(:provider_api_key, user: user, api_service_type: "zai")
        create(:llm_model, model_id: "glm-5.1", provider: "zai", tier: "high")
        wrong_model = create(:llm_model, model_id: "claude-sonnet-4-6", provider: "anthropic", tier: "high")
        provider = create(
          :provider,
          user: user,
          provider_key: "kilocode",
          auth_type: "api_key",
          provider_api_key: api_key,
          config: { "kilocode" => { "api_provider" => "zai", "model" => "glm-5.1" } }
        )

        provider.tier_model_ids = { "high" => wrong_model.model_id, "mid" => wrong_model.model_id, "low" => wrong_model.model_id }
        expect(provider).not_to be_valid
        expect(provider.errors[:tier_model_ids].join).to include("must match the configured direct-outbound model")
      end
    end

    it "validates auth_type inclusion" do
      expect(provider).to allow_value("subscription").for(:auth_type)
      expect(provider).not_to allow_value("free_trial").for(:auth_type)
    end

    it "allows api_key auth_type with a valid provider_api_key" do
      api_key = create(:provider_api_key, user: provider.user, api_service_type: "anthropic")
      provider.provider_api_key = api_key
      expect(provider).to allow_value("api_key").for(:auth_type)
    end

    it "validates fallback_role inclusion" do
      expect(provider).to allow_value("standard").for(:fallback_role)
      expect(provider).not_to allow_value("primary").for(:fallback_role)
    end

    it "allows rate_limit_fallback role on api_key providers" do
      api_key = create(:provider_api_key, user: provider.user, api_service_type: "anthropic")
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
      user = create(:user)
      create(:provider, user: user, provider_key: "cursor", auth_type: "subscription")
      duplicate = build(:provider, user: user, provider_key: "cursor", auth_type: "subscription")

      expect(duplicate).not_to be_valid
      expect(duplicate.errors[:provider_key]).to include("already has a subscription entry")
    end

    it "prevents duplicate api_key entries for the same user, provider_key, and api key" do
      api_key = create(:provider_api_key, user: provider.user, api_service_type: "anthropic")
      create(:provider, user: provider.user, provider_key: "cursor", auth_type: "api_key", provider_api_key: api_key)
      duplicate = build(:provider, user: provider.user, provider_key: "cursor", auth_type: "api_key", provider_api_key: api_key)

      expect(duplicate).not_to be_valid
      expect(duplicate.errors[:provider_key]).to include("already has an entry with this API key")
    end

    it "treats blank and nil names as duplicates for api_key entries" do
      api_key = create(:provider_api_key, user: provider.user, api_service_type: "anthropic")
      create(:provider, user: provider.user, provider_key: "cursor", auth_type: "api_key", provider_api_key: api_key)
      duplicate = build(:provider, user: provider.user, provider_key: "cursor", auth_type: "api_key", provider_api_key: api_key, name: "")

      expect(duplicate).not_to be_valid
      expect(duplicate.errors[:provider_key]).to include("already has an entry with this API key")
    end

    it "allows provider_api_key belonging to another user in the same account" do
      account = create(:account)
      provider.user = create(:user, account: account)
      other_user = create(:user, account: account)
      api_key = create(:provider_api_key, user: other_user, api_service_type: "anthropic")
      provider.auth_type = "api_key"
      provider.provider_api_key = api_key
      provider.provider_key = "cursor"

      expect(provider).to be_valid
    end

    it "rejects provider_api_key belonging to a different account" do
      other_user = create(:user)
      api_key = create(:provider_api_key, user: other_user, api_service_type: "anthropic")
      provider.auth_type = "api_key"
      provider.provider_api_key = api_key
      provider.provider_key = "cursor"

      expect(provider).not_to be_valid
      expect(provider.errors[:provider_api_key]).to include("must belong to the same account")
    end

    it "validates API key compatibility with provider_key" do
      api_key = create(:provider_api_key, user: provider.user, api_service_type: "google")
      provider.auth_type = "api_key"
      provider.provider_api_key = api_key
      provider.provider_key = "cursor"

      expect(provider).not_to be_valid
      expect(provider.errors[:provider_api_key]).to include("must be an API key for Anthropic")
    end

    it "rejects api_key auth for providers with no API service type (e.g. copilot)" do
      api_key = create(:provider_api_key, user: provider.user, api_service_type: "anthropic")
      provider.auth_type = "api_key"
      provider.provider_api_key = api_key
      provider.provider_key = "copilot"

      expect(provider).not_to be_valid
      expect(provider.errors[:provider_api_key]).to include("is not supported for this provider; use subscription authentication instead")
    end

    it "requires a model id for kilocode api_key providers" do
      api_key = create(:provider_api_key, user: provider.user, api_service_type: "inception")
      provider.auth_type = "api_key"
      provider.provider_api_key = api_key
      provider.provider_key = "kilocode"
      provider.config = { "kilocode" => { "api_provider" => "inception", "model" => "" } }

      expect(provider).not_to be_valid
      expect(provider.errors[:config]).to include("must include a KiloCode model id")
    end

    it "requires a model id for opencode api_key providers" do
      api_key = create(:provider_api_key, user: provider.user, api_service_type: "openrouter")
      provider.auth_type = "api_key"
      provider.provider_api_key = api_key
      provider.provider_key = "opencode"
      provider.config = { "opencode" => { "api_provider" => "openrouter", "model" => "" } }

      expect(provider).not_to be_valid
      expect(provider.errors[:config]).to include("must include an OpenCode model id")
    end

    describe "agent_co_author_trailer" do
      it "allows a normal single-line trailer" do
        provider.agent_co_author_trailer = "Co-Authored-By: Claude <noreply@anthropic.com>"
        expect(provider).to be_valid
      end

      it "allows blank trailer" do
        provider.agent_co_author_trailer = ""
        expect(provider).to be_valid
      end

      it "allows nil trailer" do
        provider.agent_co_author_trailer = nil
        expect(provider).to be_valid
      end

      it "rejects trailer containing newline" do
        provider.agent_co_author_trailer = "Co-Authored-By: A\nCo-Authored-By: B"
        expect(provider).not_to be_valid
        expect(provider.errors[:agent_co_author_trailer]).to include("must be a single line (no newlines)")
      end

      it "rejects trailer containing carriage return" do
        provider.agent_co_author_trailer = "Co-Authored-By: A\rB"
        expect(provider).not_to be_valid
        expect(provider.errors[:agent_co_author_trailer]).to include("must be a single line (no newlines)")
      end

      it "strips leading and trailing whitespace before validation" do
        provider.agent_co_author_trailer = "  Co-Authored-By: Claude <noreply@anthropic.com>  "
        provider.valid?
        expect(provider.agent_co_author_trailer).to eq("Co-Authored-By: Claude <noreply@anthropic.com>")
      end

      it "normalizes whitespace-only values to nil" do
        provider.agent_co_author_trailer = "   "
        provider.valid?
        expect(provider.agent_co_author_trailer).to be_nil
      end
    end
  end

  describe "scopes" do
    let(:user) { create(:user) }

    it ".subscription returns only subscription providers" do
      sub = user.providers.find_by(provider_key: "claude")
      api_key = create(:provider_api_key, user: user, api_service_type: "anthropic")
      api = user.providers.create!(provider_key: "claude", auth_type: "api_key", provider_api_key: api_key)

      expect(described_class.subscription).to include(sub)
      expect(described_class.subscription).not_to include(api)
    end

    it ".api_key returns only api_key providers" do
      sub = user.providers.find_by(provider_key: "claude")
      api_key = create(:provider_api_key, user: user, api_service_type: "anthropic")
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
      default_key = described_class.default_provider_key

      expect { described_class.ensure_default_for(user) }
        .to change { user.providers.where(provider_key: default_key).count }
        .from(0).to(1)
    end

    it "creates a subscription provider by default" do
      user.providers.delete_all
      default_key = described_class.default_provider_key

      described_class.ensure_default_for(user)
      provider = user.providers.find_by(provider_key: default_key)

      expect(provider.auth_type).to eq("subscription")
    end

    it "is idempotent" do
      default_key = described_class.default_provider_key

      expect { described_class.ensure_default_for(user) }
        .not_to change { user.providers.where(provider_key: default_key).count }
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

  describe ".for_identifier" do
    let(:user) { create(:user) }

    it "prefers the subscription entry for plain provider keys" do
      subscription = user.providers.find_by!(provider_key: "claude")
      api_key = create(:provider_api_key, user: user, api_service_type: "anthropic")
      user.providers.create!(provider_key: "claude", auth_type: "api_key", provider_api_key: api_key)

      expect(described_class.for_identifier(user, "claude")).to eq(subscription)
    end
  end

  describe "#display_name" do
    it "uses custom name when set" do
      provider = build(:provider, name: "My Custom Provider")

      expect(provider.display_name).to eq("My Custom Provider")
    end

    it "uses titleized provider_key for subscription" do
      provider = build(:provider, provider_key: "claude", auth_type: "subscription")

      expect(provider.display_name).to eq(described_class.display_name_for("claude"))
    end

    it "appends (API Key) for api_key auth type" do
      provider = build(:provider, provider_key: "claude", auth_type: "api_key", name: nil)

      expect(provider.display_name).to eq("#{described_class.display_name_for("claude")} (API Key)")
    end

    it "includes the model id for unnamed OpenCode entries" do
      provider = build(
        :provider,
        provider_key: "opencode",
        auth_type: "api_key",
        name: nil,
        config: { "opencode" => { "api_provider" => "openrouter", "model" => "moonshotai/kimi-k2-0905" } }
      )

      expect(provider.display_name).to eq("#{described_class.display_name_for("opencode")} moonshotai/kimi-k2-0905 (API Key)")
    end
  end

  describe "KiloCode config generation" do
    let(:account) { create(:account, slug: "provider-kilocode-#{SecureRandom.hex(6)}") }
    let(:user) { create(:user, account: account, email: "provider-kilocode-#{SecureRandom.hex(6)}@example.com") }
    let(:api_key) { create(:provider_api_key, user: user, api_service_type: "anthropic") }
    let(:provider) do
      create(
        :provider,
        user: user,
        provider_key: "kilocode",
        auth_type: "api_key",
        provider_api_key: api_key,
        config: { "kilocode" => { "api_provider" => "anthropic", "model" => "claude-sonnet-4-20250514" } }
      )
    end
    let(:expected_kilocode_model_entry) do
      {
        "name" => "claude-sonnet-4-20250514",
        "id" => "claude-sonnet-4-20250514",
        "tool_call" => true
      }
    end
    let(:expected_zai_model_entry) do
      {
        "name" => "glm-5.1",
        "id" => "glm-5.1",
        "tool_call" => true
      }
    end

    it "generates provider as a record with prefixed model" do
      config = JSON.parse(provider.kilocode_config_json)

      expect(config["provider"]).to eq({
        "anthropic" => {
          "options" => {
            "apiKey" => "{env:ANTHROPIC_API_KEY}",
            "baseURL" => "https://api.anthropic.com"
          },
          "models" => {
            "claude-sonnet-4-20250514" => expected_kilocode_model_entry
          }
        }
      })
      expect(config["model"]).to eq("anthropic/claude-sonnet-4-20250514")
    end

    it "does not double-prefix already-qualified model ids" do
      provider.update!(config: { "kilocode" => { "api_provider" => "anthropic", "model" => "anthropic/claude-opus-4" } })

      config = JSON.parse(provider.kilocode_config_json)

      expect(config["model"]).to eq("anthropic/claude-opus-4")
    end

    it "uses the native zai-coding-plan provider id for z.ai coding plan backends" do
      zai_key = create(:provider_api_key, user: user, api_service_type: "zai_coding")
      provider.update!(
        provider_api_key: zai_key,
        config: { "kilocode" => { "api_provider" => "zai_coding", "model" => "glm-5.1" } }
      )

      config = JSON.parse(provider.kilocode_config_json)

      expect(config["provider"]).to eq({
        "zai-coding-plan" => {
          "options" => {
            "apiKey" => "{env:ZAI_CODING_API_KEY}",
            "baseURL" => "https://api.z.ai/api/coding/paas/v4"
          },
          "models" => {
            "glm-5.1" => expected_zai_model_entry
          }
        }
      })
      expect(config["model"]).to eq("zai-coding-plan/glm-5.1")
    end
  end

  describe "Aider config infrastructure" do
    let(:account) { create(:account, slug: "provider-aider-#{SecureRandom.hex(6)}") }
    let(:user) { create(:user, account: account, email: "provider-aider-#{SecureRandom.hex(6)}@example.com") }
    let(:api_key) { create(:provider_api_key, user: user, api_service_type: "zai") }

    it "reads aider config accessors from the config hash" do
      provider = build(
        :provider,
        user: user,
        provider_key: "aider",
        auth_type: "api_key",
        provider_api_key: api_key,
        config: { "aider" => { "api_provider" => "zai", "model" => "glm-5.1" } }
      )

      expect(provider.aider_api_provider).to eq("zai")
      expect(provider.aider_model_id).to eq("glm-5.1")
      expect(provider.aider_required_api_service_type).to eq("zai")
    end

    it "defaults api_provider to openrouter when unset" do
      provider = build(:provider, provider_key: "aider", auth_type: "api_key",
        user: user, provider_api_key: api_key, config: { "aider" => { "model" => "glm-5.1" } })

      expect(provider.aider_api_provider).to eq("openrouter")
    end

    it "returns nil accessors for non-aider providers" do
      provider = build(:provider, provider_key: "claude")

      expect(provider.aider_api_provider).to be_nil
      expect(provider.aider_model_id).to be_nil
    end

    it "is not direct-outbound even when fully configured (no execution plumbing yet)" do
      provider = build(
        :provider,
        user: user,
        provider_key: "aider",
        auth_type: "api_key",
        provider_api_key: api_key,
        config: { "aider" => { "api_provider" => "zai", "model" => "glm-5.1" } }
      )

      expect(provider.requires_direct_outbound?).to be(false)
    end

    it "validates model presence for API-key aider providers when api_provider is set" do
      provider = build(
        :provider,
        user: user,
        provider_key: "aider",
        auth_type: "api_key",
        provider_api_key: api_key,
        config: { "aider" => { "api_provider" => "zai" } }
      )

      expect(provider).not_to be_valid
      expect(provider.errors[:config].join).to include("Aider model id")
    end

    it "validates model presence for API-key aider providers" do
      provider = build(
        :provider,
        user: user,
        provider_key: "aider",
        auth_type: "api_key",
        provider_api_key: api_key,
        config: { "aider" => {} }
      )

      expect(provider).not_to be_valid
      expect(provider.errors[:config].join).to include("Aider model id")
    end

    it "accepts a fully configured API-key aider provider" do
      provider = build(
        :provider,
        user: user,
        provider_key: "aider",
        auth_type: "api_key",
        provider_api_key: api_key,
        config: { "aider" => { "api_provider" => "zai", "model" => "glm-5.1" } }
      )

      expect(provider).to be_valid
    end

    it "skips aider config validation for subscription providers" do
      provider = build(:provider, provider_key: "aider", auth_type: "subscription")

      provider.valid?
      expect(provider.errors[:config]).to be_empty
    end

    it "skips aider config validation for tenant-key providers with no config" do
      user = create(:user)
      api_key = create(:provider_api_key, user: user, api_service_type: "anthropic")
      provider = build(
        :provider,
        user: user,
        provider_key: "aider",
        auth_type: "api_key",
        provider_api_key: api_key,
        config: nil
      )

      provider.valid?
      expect(provider.errors[:config]).to be_empty
    end
  end

  describe "sync_direct_outbound_tier_models callback" do
    let(:account) { create(:account, slug: "sync-tier-#{SecureRandom.hex(6)}") }
    let(:user) { create(:user, account: account, email: "sync-tier-#{SecureRandom.hex(6)}@example.com") }
    let(:api_key) { create(:provider_api_key, user: user, api_service_type: "openrouter") }

    it "clears stale tier_model_ids when provider no longer qualifies for direct-outbound" do
      provider = create(
        :provider,
        user: user,
        provider_key: "opencode",
        auth_type: "api_key",
        provider_api_key: api_key,
        config: { "opencode" => { "api_provider" => "openrouter", "model" => "test-model-1" } }
      )

      expect(provider.tier_model_ids).to be_present

      provider.update_columns(config: { "opencode" => { "api_provider" => "openrouter" } })

      provider.valid?
      expect(provider.tier_model_ids).to be_blank
    end

    it "clears stale tier_model_ids when model is removed from config" do
      provider = create(
        :provider,
        user: user,
        provider_key: "kilocode",
        auth_type: "api_key",
        provider_api_key: api_key,
        config: { "kilocode" => { "api_provider" => "openrouter", "model" => "test-model-2" } }
      )

      expect(provider.tier_model_ids).to be_present

      provider.update_columns(config: { "kilocode" => { "api_provider" => "openrouter", "model" => "" } })

      provider.valid?
      expect(provider.tier_model_ids).to be_blank
    end

    it "preserves tier_model_ids on unrelated attribute saves when config is unchanged" do
      provider = create(
        :provider,
        user: user,
        provider_key: "opencode",
        auth_type: "api_key",
        provider_api_key: api_key,
        config: { "opencode" => { "api_provider" => "openrouter", "model" => "test-model-3" } }
      )

      original_tier_model_ids = provider.tier_model_ids.dup
      provider.update!(name: "Renamed Provider")

      expect(provider.reload.tier_model_ids).to eq(original_tier_model_ids)
    end

    it "updates tier_model_ids when the configured model changes" do
      provider = create(
        :provider,
        user: user,
        provider_key: "opencode",
        auth_type: "api_key",
        provider_api_key: api_key,
        config: { "opencode" => { "api_provider" => "openrouter", "model" => "test-model-old" } }
      )

      provider.update!(config: { "opencode" => { "api_provider" => "openrouter", "model" => "test-model-new" } })

      expect(provider.reload.tier_model_ids.values.uniq).to eq([ "test-model-new" ])
    end

    it "reactivates an inactive LlmModel when reused for a direct-outbound provider" do
      inactive_model = create(:llm_model, model_id: "inactive-test-model", provider: "zai", tier: "mid", active: false)

      provider = create(
        :provider,
        user: user,
        provider_key: "opencode",
        auth_type: "api_key",
        provider_api_key: api_key,
        config: { "opencode" => { "api_provider" => "openrouter", "model" => "inactive-test-model" } }
      )

      expect(inactive_model.reload).to be_active
      expect(provider.tier_model_ids.values.uniq).to eq([ "inactive-test-model" ])
    end
  end

  describe "OpenCode agent-harness runtime helpers" do
    let(:user) { create(:user) }
    let(:api_key) { create(:provider_api_key, user: user, api_service_type: "openrouter", api_key: "sk-openrouter-secret") }
    let(:provider) do
      create(
        :provider,
        user: user,
        provider_key: "opencode",
        auth_type: "api_key",
        provider_api_key: api_key,
        config: { "opencode" => { "api_provider" => "openrouter", "model" => "moonshotai/kimi-k2-0905" } }
      )
    end

    it "builds provider runtime inputs instead of a local bootstrap wrapper" do
      runtime = provider.agent_harness_provider_runtime

      expect(runtime.model).to eq("openrouter/moonshotai/kimi-k2-0905")
      expect(runtime.api_provider).to be_nil
      expect(runtime.base_url).to be_nil
      expect(runtime.env).to include(
        "OPENROUTER_API_KEY" => "sk-openrouter-secret",
        "OPENAI_BASE_URL" => "https://openrouter.ai/api/v1"
      )
      expect(runtime.unset_env).to include("OPENAI_HEADER_X_AGENT_RUN_ID", "OPENAI_HEADER_X_PROXY_TOKEN")
      expect(runtime.metadata[:config]["provider"]).to eq({ "openrouter" => {} })
    end

    it "does not enable direct outbound when the OpenCode model id is missing" do
      provider = build(
        :provider,
        user: user,
        provider_key: "opencode",
        auth_type: "api_key",
        provider_api_key: api_key,
        config: { "opencode" => { "api_provider" => "openrouter" } }
      )

      expect(provider.requires_direct_outbound?).to be(false)
      expect(provider.direct_outbound_exec_env).to eq({})
      expect(provider.direct_outbound_exec_command(command_prefix: %w[opencode run], prompt: "ping")).to eq(%w[opencode run ping])
      expect(provider.agent_harness_provider_runtime).to be_nil
    end
  end

  describe "#agent_harness_runtime?" do
    it "returns true for copilot providers" do
      provider = build(:provider, provider_key: "copilot")

      expect(provider.agent_harness_runtime?).to be(true)
    end

    it "returns true for opencode direct-outbound providers" do
      user = create(:user)
      api_key = create(:provider_api_key, user: user, api_service_type: "openrouter", api_key: "sk-test")
      provider = build(
        :provider,
        user: user,
        provider_key: "opencode",
        auth_type: "api_key",
        provider_api_key: api_key,
        config: { "opencode" => { "api_provider" => "openrouter", "model" => "test-model" } }
      )

      expect(provider.agent_harness_runtime?).to be(true)
    end

    it "returns false for claude providers" do
      provider = build(:provider, provider_key: "claude")

      expect(provider.agent_harness_runtime?).to be(false)
    end

    it "returns false for opencode subscription providers" do
      provider = build(:provider, provider_key: "opencode", auth_type: "subscription")

      expect(provider.agent_harness_runtime?).to be(false)
    end
  end

  describe "#state_key" do
    it "uses the canonical provider key for subscription entries" do
      provider = build(:provider, provider_key: "claude", auth_type: "subscription")

      expect(provider.state_key).to eq("claude")
    end

    it "uses the routing key for api-key entries" do
      user = create(:user)
      api_key = create(:provider_api_key, user: user, api_service_type: "anthropic")
      provider = create(:provider, :api_key, user: user, provider_key: "claude", provider_api_key: api_key)

      expect(provider.state_key).to eq(provider.routing_key)
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
      api_key = create(:provider_api_key, user: user, api_service_type: "anthropic")
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

  describe "soft delete lifecycle" do
    it "clears the API key reference when discarding an api-key provider" do
      user = create(:user)
      api_key = create(:provider_api_key, user: user, api_service_type: "anthropic")
      provider = create(:provider, :api_key, user: user, provider_key: "cursor", provider_api_key: api_key)

      expect(provider.discard).to be(true)

      discarded_provider = described_class.with_discarded.find(provider.id)
      expect(discarded_provider).to be_discarded
      expect(discarded_provider.provider_api_key_id).to be_nil
    end
  end
end
