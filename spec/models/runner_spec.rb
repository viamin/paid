# frozen_string_literal: true

require "rails_helper"
require "securerandom"

RSpec.describe Runner do
  describe "#effective_api_secret" do
    it "returns the integration credential secret for active account-managed runners" do
      account = create(:account)
      user = create(:user, :owner, account: account)
      integration_credential = create(
        :integration_credential,
        account: account,
        created_by: user,
        service_key: "claude",
        auth_kind: "api_key",
        secret: "sk-ant-managed"
      )
      runner = create(
        :runner,
        user: user,
        runner_key: "claude",
        auth_type: "api_key",
        provider_api_key: nil,
        integration_credential: integration_credential
      )

      expect(runner.effective_api_secret).to eq("sk-ant-managed")
    end
  end

  describe "associations" do
    it { is_expected.to belong_to(:user) }
    it { is_expected.to belong_to(:provider_api_key).optional }
    it { is_expected.to belong_to(:integration_credential).optional }
  end

  describe "validations" do
    subject(:runner) { build(:runner) }

    it { is_expected.to validate_presence_of(:runner_key) }
    it { is_expected.to validate_presence_of(:auth_type) }
    it { is_expected.to validate_presence_of(:fallback_role) }

    it "validates runner_key against agent harness-supported providers" do
      expect(runner).to allow_value("cursor").for(:runner_key)
      expect(runner).to allow_value("gemini").for(:runner_key)
      expect(runner).not_to allow_value("unknown_provider").for(:runner_key)
    end

    describe "weight" do
      it "defaults to 1 on new records" do
        expect(runner.weight).to eq(1)
      end

      it "accepts positive integer values up to MAX_WEIGHT" do
        runner.weight = 1
        expect(runner).to be_valid

        runner.weight = described_class::MAX_WEIGHT
        expect(runner).to be_valid
      end

      it "rejects zero or negative weights" do
        runner.weight = 0
        expect(runner).not_to be_valid
        expect(runner.errors[:weight]).to be_present
      end

      it "rejects weights above MAX_WEIGHT" do
        runner.weight = described_class::MAX_WEIGHT + 1
        expect(runner).not_to be_valid
        expect(runner.errors[:weight]).to be_present
      end
    end

    describe "monthly_token_budget" do
      it "allows nil" do
        runner.monthly_token_budget = nil

        expect(runner).to be_valid
      end

      it "accepts positive integers" do
        runner.monthly_token_budget = 100_000

        expect(runner).to be_valid
      end

      it "rejects zero" do
        runner.monthly_token_budget = 0

        expect(runner).not_to be_valid
        expect(runner.errors[:monthly_token_budget]).to be_present
      end
    end

    describe "complexity_thresholds" do
      let(:runner) { build(:runner, runner_key: "cursor") }

      it "is valid with the default thresholds" do
        expect(runner).to be_valid
      end

      it "accepts custom integer thresholds" do
        runner.complexity_thresholds = { "low_max" => 2, "mid_max" => 8 }
        expect(runner).to be_valid
      end

      it "rejects unknown threshold keys" do
        runner.complexity_thresholds = { "ultra_max" => 5 }
        expect(runner).not_to be_valid
        expect(runner.errors[:complexity_thresholds].join).to include("unknown key")
      end

      it "rejects non-integer values" do
        runner.complexity_thresholds = { "low_max" => "nope", "mid_max" => 7 }
        expect(runner).not_to be_valid
        expect(runner.errors[:complexity_thresholds].join).to include("integer")
      end

      it "rejects out-of-range values" do
        runner.complexity_thresholds = { "low_max" => 0, "mid_max" => 7 }
        expect(runner).not_to be_valid
        expect(runner.errors[:complexity_thresholds].join).to include("between 1 and 10")
      end

      it "rejects low_max >= mid_max" do
        runner.complexity_thresholds = { "low_max" => 7, "mid_max" => 5 }
        expect(runner).not_to be_valid
        expect(runner.errors[:complexity_thresholds].join).to include("less than mid_max")
      end

      it "rejects a partial low_max that is inconsistent with the default mid_max" do
        runner.complexity_thresholds = { "low_max" => 8 }
        expect(runner).not_to be_valid
        expect(runner.errors[:complexity_thresholds].join).to include("less than mid_max")
      end

      it "rejects a partial mid_max that is inconsistent with the default low_max" do
        runner.complexity_thresholds = { "mid_max" => 2 }
        expect(runner).not_to be_valid
        expect(runner.errors[:complexity_thresholds].join).to include("less than mid_max")
      end

      it "exposes a merged-with-defaults hash via effective_complexity_thresholds" do
        runner.complexity_thresholds = { "low_max" => 4 }
        expect(runner.effective_complexity_thresholds).to eq("low_max" => 4, "mid_max" => 7)
      end
    end

    describe "#effective_no_progress_thresholds" do
      let(:runner) { build(:runner) }

      it "returns the defaults when no overrides are stored" do
        expect(runner.effective_no_progress_thresholds).to eq(
          "min_input_tokens" => 100_000,
          "max_output_tokens" => 100
        )
      end

      it "overlays stored overrides on top of defaults" do
        runner.no_progress_thresholds = { "min_input_tokens" => 200_000 }
        expect(runner.effective_no_progress_thresholds).to eq(
          "min_input_tokens" => 200_000,
          "max_output_tokens" => 100
        )
      end

      it "coerces string values from JSONB round-trips to integers" do
        runner.no_progress_thresholds = { "min_input_tokens" => "50000", "max_output_tokens" => "20" }
        result = runner.effective_no_progress_thresholds
        expect(result["min_input_tokens"]).to eq(50_000)
        expect(result["max_output_tokens"]).to eq(20)
      end

      it "ignores unrecognized keys" do
        runner.no_progress_thresholds = { "min_input_tokens" => 50_000, "unknown_key" => 999 }
        expect(runner.effective_no_progress_thresholds).not_to have_key("unknown_key")
      end
    end

    describe "no_progress_thresholds validation" do
      let(:runner) { build(:runner, runner_key: "cursor") }

      it "is valid when blank" do
        runner.no_progress_thresholds = nil
        expect(runner).to be_valid
      end

      it "accepts valid positive integer thresholds" do
        runner.no_progress_thresholds = { "min_input_tokens" => 200_000, "max_output_tokens" => 50 }
        expect(runner).to be_valid
      end

      it "rejects a non-hash value" do
        runner.no_progress_thresholds = "off"
        expect(runner).not_to be_valid
        expect(runner.errors[:no_progress_thresholds].join).to include("must be a hash")
      end

      it "rejects unknown threshold keys" do
        runner.no_progress_thresholds = { "unknown_key" => 100 }
        expect(runner).not_to be_valid
        expect(runner.errors[:no_progress_thresholds].join).to include("unknown key")
      end

      it "rejects non-integer values" do
        runner.no_progress_thresholds = { "min_input_tokens" => "off" }
        expect(runner).not_to be_valid
        expect(runner.errors[:no_progress_thresholds].join).to include("positive integer")
      end

      it "rejects zero values" do
        runner.no_progress_thresholds = { "min_input_tokens" => 0 }
        expect(runner).not_to be_valid
        expect(runner.errors[:no_progress_thresholds].join).to include("positive integer")
      end

      it "rejects negative values" do
        runner.no_progress_thresholds = { "max_output_tokens" => -1 }
        expect(runner).not_to be_valid
        expect(runner.errors[:no_progress_thresholds].join).to include("positive integer")
      end
    end

    describe "tier_model_ids" do
      let(:runner) { build(:runner, runner_key: "cursor") }

      it "is valid when blank" do
        runner.tier_model_ids = {}
        expect(runner).to be_valid
      end

      it "rejects unknown tier keys" do
        runner.tier_model_ids = { "ultra" => "x" }
        expect(runner).not_to be_valid
        expect(runner.errors[:tier_model_ids].join).to include("invalid tier")
      end

      it "rejects references to unknown models" do
        runner.tier_model_ids = { "low" => "no-such-model" }
        expect(runner).not_to be_valid
        expect(runner.errors[:tier_model_ids].join).to include("unknown model")
      end

      it "rejects models that belong to a different runner" do
        create(:llm_model, model_id: "gpt-low", provider: "openai", tier: "low")
        runner.tier_model_ids = { "low" => "gpt-low" }
        expect(runner).not_to be_valid
        expect(runner.errors[:tier_model_ids].join).to include("does not belong")
      end

      it "accepts models that belong to the runner" do
        create(:llm_model, model_id: "haiku-y", provider: "anthropic", tier: "low")
        runner.tier_model_ids = { "low" => "haiku-y" }
        expect(runner).to be_valid
      end

      it "rejects tier_model_ids for providers without a tier mapping" do
        unmapped = build(:runner, runner_key: "copilot")
        unmapped.tier_model_ids = { "low" => "anything" }
        expect(unmapped).not_to be_valid
        expect(unmapped.errors[:tier_model_ids].join).to include("not configurable")
      end

      it "allows direct-outbound providers to reference models from any upstream runner" do
        user = create(:user)
        api_key = create(:provider_api_key, user: user, api_service_type: "zai")
        create(:llm_model, model_id: "glm-5.1", provider: "zai", tier: "high")
        runner = build(
          :runner,
          user: user,
          runner_key: "kilocode",
          auth_type: "api_key",
          provider_api_key: api_key,
          config: { "kilocode" => { "api_provider" => "zai", "model" => "glm-5.1" } },
          tier_model_ids: { "high" => "glm-5.1", "mid" => "glm-5.1", "low" => "glm-5.1" }
        )

        expect(runner).to be_valid
      end

      it "allows Pi runners with a configured model to reference upstream MiniMax models" do
        user = create(:user)
        api_key = create(:provider_api_key, user: user, api_service_type: "minimax")
        create(:llm_model, model_id: "MiniMax-M2.7", provider: "minimax", tier: "high")
        runner = build(
          :runner,
          user: user,
          runner_key: "pi",
          auth_type: "api_key",
          provider_api_key: api_key,
          config: { "pi" => { "api_provider" => "minimax", "model" => "MiniMax-M2.7" } },
          tier_model_ids: { "high" => "MiniMax-M2.7", "mid" => "MiniMax-M2.7", "low" => "MiniMax-M2.7" }
        )

        expect(runner).to be_valid
      end

      it "rejects partial tier_model_ids for direct-outbound providers" do
        user = create(:user)
        api_key = create(:provider_api_key, user: user, api_service_type: "zai")
        create(:llm_model, model_id: "glm-5.1", provider: "zai", tier: "high")
        runner = create(
          :runner,
          user: user,
          runner_key: "kilocode",
          auth_type: "api_key",
          provider_api_key: api_key,
          config: { "kilocode" => { "api_provider" => "zai", "model" => "glm-5.1" } }
        )

        runner.tier_model_ids = { "high" => "glm-5.1" }
        expect(runner).not_to be_valid
        expect(runner.errors[:tier_model_ids].join).to include("must map all tiers")
      end

      it "rejects partial tier_model_ids for Pi runners with a fixed model" do
        user = create(:user)
        api_key = create(:provider_api_key, user: user, api_service_type: "minimax")
        create(:llm_model, model_id: "MiniMax-M2.7", provider: "minimax", tier: "high")
        runner = create(
          :runner,
          user: user,
          runner_key: "pi",
          auth_type: "api_key",
          provider_api_key: api_key,
          config: { "pi" => { "api_provider" => "minimax", "model" => "MiniMax-M2.7" } }
        )

        runner.tier_model_ids = { "high" => "MiniMax-M2.7" }
        expect(runner).not_to be_valid
        expect(runner.errors[:tier_model_ids].join).to include("must map all tiers")
      end

      it "rejects crafted tier_model_ids that pin a direct-outbound runner to a different model" do
        user = create(:user)
        api_key = create(:provider_api_key, user: user, api_service_type: "zai")
        create(:llm_model, model_id: "glm-5.1", provider: "zai", tier: "high")
        wrong_model = create(:llm_model, model_id: "claude-sonnet-4-6", provider: "anthropic", tier: "high")
        runner = create(
          :runner,
          user: user,
          runner_key: "kilocode",
          auth_type: "api_key",
          provider_api_key: api_key,
          config: { "kilocode" => { "api_provider" => "zai", "model" => "glm-5.1" } }
        )

        runner.tier_model_ids = { "high" => wrong_model.model_id, "mid" => wrong_model.model_id, "low" => wrong_model.model_id }
        expect(runner).not_to be_valid
        expect(runner.errors[:tier_model_ids].join).to include("must match the configured direct-outbound model")
      end

      it "rejects crafted tier_model_ids that pin a Pi runner to a different model" do
        user = create(:user)
        api_key = create(:provider_api_key, user: user, api_service_type: "minimax")
        create(:llm_model, model_id: "MiniMax-M2.7", provider: "minimax", tier: "high")
        wrong_model = create(:llm_model, model_id: "claude-sonnet-4-6", provider: "anthropic", tier: "high")
        runner = create(
          :runner,
          user: user,
          runner_key: "pi",
          auth_type: "api_key",
          provider_api_key: api_key,
          config: { "pi" => { "api_provider" => "minimax", "model" => "MiniMax-M2.7" } }
        )

        runner.tier_model_ids = { "high" => wrong_model.model_id, "mid" => wrong_model.model_id, "low" => wrong_model.model_id }
        expect(runner).not_to be_valid
        expect(runner.errors[:tier_model_ids].join).to include("must match the configured direct-outbound model")
      end

      it "rejects crafted tier_model_ids that pin a free-policy opencode runner to a paid model" do
        user = create(:user)
        api_key = create(:provider_api_key, user: user, api_service_type: "openrouter")
        create(:llm_model, model_id: "free-mid", provider: "deepseek", tier: "mid", pricing_tier: "free")
        paid_model = create(:llm_model, model_id: "claude-sonnet-4-6", provider: "anthropic", tier: "mid", pricing_tier: "paid")
        runner = create(:runner, user: user, runner_key: "opencode", auth_type: "api_key", provider_api_key: api_key,
          config: { "opencode" => { "model_policy" => "free" } })

        runner.tier_model_ids = LlmModel::TIERS.index_with { paid_model.model_id }
        expect(runner).not_to be_valid
        expect(runner.errors[:tier_model_ids].join).to include("must reference free models")
      end

      it "accepts free tier_model_ids for a free-policy opencode runner" do
        user = create(:user)
        api_key = create(:provider_api_key, user: user, api_service_type: "openrouter")
        free_model = create(:llm_model, model_id: "free-mid", provider: "deepseek", tier: "mid", pricing_tier: "free")
        runner = create(:runner, user: user, runner_key: "opencode", auth_type: "api_key", provider_api_key: api_key,
          config: { "opencode" => { "model_policy" => "free" } })

        runner.tier_model_ids = LlmModel::TIERS.index_with { free_model.model_id }
        expect(runner).to be_valid
      end
    end

    describe "tier_models" do
      let(:runner) { build(:runner, runner_key: "cursor") }

      it "coerces provider_id values to integers" do
        runner.tier_models = { low: { model_id: "haiku-x", provider_id: "17" } }

        expect(runner.tier_models).to eq("low" => { "model_id" => "haiku-x", "provider_id" => 17 })
      end

      it "rejects unknown tier keys" do
        runner.tier_models = { ultra: { model_id: "haiku-x", provider_id: 17 } }

        expect(runner).not_to be_valid
        expect(runner.errors[:tier_models].join).to include("invalid tier")
      end

      it "rejects entries without a model_id" do
        runner.tier_models = { low: { provider_id: 17 } }

        expect(runner).not_to be_valid
        expect(runner.errors[:tier_models].join).to include("model_id")
      end

      it "rejects entries without an integer provider_id" do
        runner.tier_models = { low: { model_id: "haiku-x", provider_id: "abc" } }

        expect(runner).not_to be_valid
        expect(runner.errors[:tier_models].join).to include("provider_id")
      end

      it "rejects paid tier_models entries for a free-policy opencode runner" do
        user = create(:user)
        api_key = create(:provider_api_key, user: user, api_service_type: "openrouter")
        create(:llm_model, model_id: "free-mid", provider: "deepseek", tier: "mid", pricing_tier: "free")
        paid_model = create(:llm_model, model_id: "claude-sonnet-4-6", provider: "anthropic", tier: "mid", pricing_tier: "paid")
        free_policy_runner = create(:runner, user: user, runner_key: "opencode", auth_type: "api_key", provider_api_key: api_key,
          config: { "opencode" => { "model_policy" => "free" } })

        free_policy_runner.tier_models = { mid: { model_id: paid_model.model_id, provider_id: free_policy_runner.id } }
        expect(free_policy_runner).not_to be_valid
        expect(free_policy_runner.errors[:tier_models].join).to include("must reference a free model")
      end

      context "when runner compatibility validation is applied" do
        it "accepts gpt-5.5 in tier_models for codex with the updated CLI pin" do
          user = create(:user)
          api_key = create(:provider_api_key, user: user, api_service_type: "openai")
          create(:llm_model, :openai, model_id: "gpt-5.5")
          runner = build(
            :runner, :api_key,
            user: user,
            runner_key: "codex",
            provider_api_key: api_key,
            tier_models: { "mid" => { "model_id" => "gpt-5.5", "provider_id" => 1 } }
          )

          expect(runner).to be_valid
        end

        it "accepts compatible models in tier_models for codex" do
          user = create(:user)
          api_key = create(:provider_api_key, user: user, api_service_type: "openai")
          create(:llm_model, :openai, model_id: "gpt-5.4")
          runner = build(
            :runner, :api_key,
            user: user,
            runner_key: "codex",
            provider_api_key: api_key,
            tier_models: { "mid" => { "model_id" => "gpt-5.4", "provider_id" => 1 } }
          )

          expect(runner).to be_valid
        end

        it "rejects cross-provider models in tier_models (e.g. openai model for claude)" do
          create(:llm_model, :openai, model_id: "gpt-5.4")
          runner = build(:runner, runner_key: "claude",
            tier_models: { "mid" => { "model_id" => "gpt-5.4", "provider_id" => 1 } })

          expect(runner).not_to be_valid
          expect(runner.errors[:tier_models].join).to include("not compatible")
        end
      end
    end

    describe "tier_model_ids runner compatibility" do
      it "accepts gpt-5.5 in tier_model_ids for codex with the updated CLI pin" do
        user = create(:user)
        api_key = create(:provider_api_key, user: user, api_service_type: "openai")
        create(:llm_model, :openai, model_id: "gpt-5.5")
        runner = build(
          :runner, :api_key,
          user: user,
          runner_key: "codex",
          provider_api_key: api_key,
          tier_model_ids: { "high" => "gpt-5.5" }
        )

        expect(runner).to be_valid
      end

      it "skips compatibility check for direct-outbound runners" do
        user = create(:user)
        api_key = create(:provider_api_key, user: user, api_service_type: "openai")
        create(:llm_model, :openai, model_id: "gpt-5.5")
        runner = build(
          :runner, :api_key,
          user: user,
          runner_key: "opencode",
          provider_api_key: api_key,
          config: { "opencode" => { "api_provider" => "openai", "model" => "gpt-5.5" } },
          tier_model_ids: { "high" => "gpt-5.5", "mid" => "gpt-5.5", "low" => "gpt-5.5" }
        )

        # opencode is direct-outbound — compatibility check is skipped
        expect(runner.errors[:tier_model_ids]).not_to include(
          a_string_including("not compatible")
        )
      end
    end

    it "validates auth_type inclusion" do
      expect(runner).to allow_value("subscription").for(:auth_type)
      expect(runner).not_to allow_value("free_trial").for(:auth_type)
    end

    it "allows api_key auth_type with a valid provider_api_key" do
      api_key = create(:provider_api_key, user: runner.user, api_service_type: "anthropic")
      runner.provider_api_key = api_key
      expect(runner).to allow_value("api_key").for(:auth_type)
    end

    it "validates fallback_role inclusion" do
      expect(runner).to allow_value("standard").for(:fallback_role)
      expect(runner).not_to allow_value("primary").for(:fallback_role)
    end

    it "allows rate_limit_fallback role on api_key providers" do
      api_key = create(:provider_api_key, user: runner.user, api_service_type: "anthropic")
      runner.auth_type = "api_key"
      runner.provider_api_key = api_key
      expect(runner).to allow_value("rate_limit_fallback").for(:fallback_role)
    end

    it "requires standard fallback_role for subscription runners" do
      runner.auth_type = "subscription"
      runner.fallback_role = "rate_limit_fallback"

      expect(runner).not_to be_valid
      expect(runner.errors[:fallback_role]).to include("must be standard for subscription runners")
    end

    it "requires provider_api_key for api_key auth type" do
      runner.auth_type = "api_key"
      runner.provider_api_key = nil

      expect(runner).not_to be_valid
      expect(runner.errors[:provider_api_key]).to include("is required for API key authentication")
    end

    it "rejects a non-existent provider_api_key_id for api_key auth type" do
      runner.auth_type = "api_key"
      runner.provider_api_key_id = -1

      expect(runner).not_to be_valid
      expect(runner.errors[:provider_api_key]).to include("is required for API key authentication")
    end

    it "rejects provider_api_key for subscription auth type" do
      api_key = create(:provider_api_key, user: runner.user)
      runner.auth_type = "subscription"
      runner.provider_api_key = api_key

      expect(runner).not_to be_valid
      expect(runner.errors[:provider_api_key]).to include("must not be set for subscription authentication")
    end

    it "rejects integration_credential for subscription auth type" do
      credential = create(:integration_credential, account: runner.user.account, created_by: runner.user, category: "llm_provider")
      runner.auth_type = "subscription"
      runner.integration_credential = credential

      expect(runner).not_to be_valid
      expect(runner.errors[:integration_credential]).to include("must not be set for subscription authentication")
    end

    it "prevents duplicate subscription entries for the same user and runner_key" do
      user = create(:user)
      create(:runner, user: user, runner_key: "cursor", auth_type: "subscription")
      duplicate = build(:runner, user: user, runner_key: "cursor", auth_type: "subscription")

      expect(duplicate).not_to be_valid
      expect(duplicate.errors[:runner_key]).to include("already has a subscription entry")
    end

    it "prevents duplicate api_key entries for the same user, runner_key, and api key" do
      api_key = create(:provider_api_key, user: runner.user, api_service_type: "anthropic")
      create(:runner, user: runner.user, runner_key: "cursor", auth_type: "api_key", provider_api_key: api_key)
      duplicate = build(:runner, user: runner.user, runner_key: "cursor", auth_type: "api_key", provider_api_key: api_key)

      expect(duplicate).not_to be_valid
      expect(duplicate.errors[:runner_key]).to include("already has an entry with this API key")
    end

    it "treats blank and nil names as duplicates for api_key entries" do
      api_key = create(:provider_api_key, user: runner.user, api_service_type: "anthropic")
      create(:runner, user: runner.user, runner_key: "cursor", auth_type: "api_key", provider_api_key: api_key)
      duplicate = build(:runner, user: runner.user, runner_key: "cursor", auth_type: "api_key", provider_api_key: api_key, name: "")

      expect(duplicate).not_to be_valid
      expect(duplicate.errors[:runner_key]).to include("already has an entry with this API key")
    end

    it "allows provider_api_key belonging to another user in the same account" do
      account = create(:account)
      runner.user = create(:user, account: account)
      other_user = create(:user, account: account)
      api_key = create(:provider_api_key, user: other_user, api_service_type: "anthropic")
      runner.auth_type = "api_key"
      runner.provider_api_key = api_key
      runner.runner_key = "cursor"

      expect(runner).to be_valid
    end

    it "rejects provider_api_key belonging to a different account" do
      other_user = create(:user)
      api_key = create(:provider_api_key, user: other_user, api_service_type: "anthropic")
      runner.auth_type = "api_key"
      runner.provider_api_key = api_key
      runner.runner_key = "cursor"

      expect(runner).not_to be_valid
      expect(runner.errors[:provider_api_key]).to include("must belong to the same account")
    end

    it "validates API key compatibility with runner_key" do
      api_key = create(:provider_api_key, user: runner.user, api_service_type: "google")
      runner.auth_type = "api_key"
      runner.provider_api_key = api_key
      runner.runner_key = "cursor"

      expect(runner).not_to be_valid
      expect(runner.errors[:provider_api_key]).to include("must be an API key for Anthropic")
    end

    it "rejects api_key auth for providers with no API service type (e.g. copilot)" do
      api_key = create(:provider_api_key, user: runner.user, api_service_type: "anthropic")
      runner.auth_type = "api_key"
      runner.provider_api_key = api_key
      runner.runner_key = "copilot"

      expect(runner).not_to be_valid
      expect(runner.errors[:provider_api_key]).to include("is not supported for this runner; use subscription authentication instead")
    end

    it "requires a model id for kilocode api_key providers" do
      api_key = create(:provider_api_key, user: runner.user, api_service_type: "inception")
      runner.auth_type = "api_key"
      runner.provider_api_key = api_key
      runner.runner_key = "kilocode"
      runner.config = { "kilocode" => { "api_provider" => "inception", "model" => "" } }

      expect(runner).not_to be_valid
      expect(runner.errors[:config]).to include("must include a KiloCode model id")
    end

    it "requires kilocode preflight timeout overrides to be positive integers" do
      api_key = create(:provider_api_key, user: runner.user, api_service_type: "inception")
      create(:llm_model, model_id: "glm-5.1", provider: "inception", tier: "mid")
      runner.auth_type = "api_key"
      runner.provider_api_key = api_key
      runner.runner_key = "kilocode"
      runner.config = { "kilocode" => { "api_provider" => "inception", "model" => "glm-5.1", "preflight_timeout_seconds" => "0" } }

      expect(runner).not_to be_valid
      expect(runner.errors[:config]).to include("must include a KiloCode preflight timeout of at least 1 second")
    end

    it "requires a model id for opencode api_key providers" do
      api_key = create(:provider_api_key, user: runner.user, api_service_type: "openrouter")
      runner.auth_type = "api_key"
      runner.provider_api_key = api_key
      runner.runner_key = "opencode"
      runner.config = { "opencode" => { "api_provider" => "openrouter", "model" => "" } }

      expect(runner).not_to be_valid
      expect(runner.errors[:config]).to include("must include an OpenCode model id")
    end

    it "rejects an invalid preflight_timeout_seconds for opencode api_key providers" do
      api_key = create(:provider_api_key, user: runner.user, api_service_type: "openrouter")
      create(:llm_model, model_id: "meta-llama/llama-4-maverick", provider: "openrouter", tier: "mid")
      runner.auth_type = "api_key"
      runner.provider_api_key = api_key
      runner.runner_key = "opencode"
      runner.config = { "opencode" => { "api_provider" => "openrouter", "model" => "meta-llama/llama-4-maverick", "preflight_timeout_seconds" => "0" } }

      expect(runner).not_to be_valid
      expect(runner.errors[:config]).to include("must include an OpenCode preflight timeout of at least 1 second")
    end

    it "reads an optional preflight timeout override for opencode from config" do
      api_key = create(:provider_api_key, user: runner.user, api_service_type: "openrouter")
      create(:llm_model, model_id: "meta-llama/llama-4-maverick", provider: "openrouter", tier: "mid")
      runner.auth_type = "api_key"
      runner.provider_api_key = api_key
      runner.runner_key = "opencode"
      runner.config = { "opencode" => { "api_provider" => "openrouter", "model" => "meta-llama/llama-4-maverick", "preflight_timeout_seconds" => "90" } }
      runner.save!

      expect(runner.opencode_preflight_timeout_seconds).to eq(90)
      expect(runner.runner_preflight_timeout_seconds).to eq(90)
    end

    it "creates a manual catalog row for an OpenCode model id that is not present in the seeded catalog (#2669)" do
      api_key = create(:provider_api_key, user: runner.user, api_service_type: "minimax")
      runner.auth_type = "api_key"
      runner.provider_api_key = api_key
      runner.runner_key = "opencode"
      runner.config = { "opencode" => { "api_provider" => "minimax", "model" => "MiniMax-M3" } }

      expect(runner).to be_valid
      expect { runner.save! }.to change { LlmModel.where(catalog_source: "manual", model_id: "MiniMax-M3").count }.by(1)

      seeded = LlmModel.find_by!(model_id: "MiniMax-M3")
      expect(seeded.provider).to eq("minimax")
      expect(seeded.catalog_source).to eq("manual")
    end

    it "stores the manual catalog row under the bare model id when given a provider-qualified OpenCode model id" do
      api_key = create(:provider_api_key, user: runner.user, api_service_type: "minimax")
      runner.auth_type = "api_key"
      runner.provider_api_key = api_key
      runner.runner_key = "opencode"
      runner.config = { "opencode" => { "api_provider" => "minimax", "model" => "minimax/MiniMax-M3" } }

      expect { runner.save! }.to change { LlmModel.where(model_id: "MiniMax-M3", catalog_source: "manual").count }.by(1)
      expect(LlmModel.find_by(model_id: "minimax/MiniMax-M3")).to be_nil
    end

    it "creates a manual catalog row for a KiloCode model id that is not present in the seeded catalog (#2669)" do
      api_key = create(:provider_api_key, user: runner.user, api_service_type: "zai_coding")
      runner.auth_type = "api_key"
      runner.provider_api_key = api_key
      runner.runner_key = "kilocode"
      runner.config = { "kilocode" => { "api_provider" => "zai_coding", "model" => "glm-6" } }

      expect(runner).to be_valid
      expect { runner.save! }.to change { LlmModel.where(catalog_source: "manual", model_id: "glm-6").count }.by(1)

      seeded = LlmModel.find_by!(model_id: "glm-6")
      expect(seeded.provider).to eq("zai_coding")
    end

    it "accepts a provider-qualified OpenCode model id when the catalog stores the canonical bare model id" do
      api_key = create(:provider_api_key, user: runner.user, api_service_type: "minimax")
      create(:llm_model, model_id: "MiniMax-M3", provider: "minimax", tier: "mid")
      runner.auth_type = "api_key"
      runner.provider_api_key = api_key
      runner.runner_key = "opencode"
      runner.config = { "opencode" => { "api_provider" => "minimax", "model" => "minimax/MiniMax-M3" } }

      expect(runner).to be_valid
    end

    it "uses the human-readable service-type label on both sides of the catalog-provider mismatch message" do
      api_key = create(:provider_api_key, user: runner.user, api_service_type: "minimax")
      create(:llm_model, model_id: "mercury-2", provider: "inception", tier: "mid")
      runner.auth_type = "api_key"
      runner.provider_api_key = api_key
      runner.runner_key = "opencode"
      runner.config = { "opencode" => { "api_provider" => "minimax", "model" => "mercury-2" } }

      expect(runner).not_to be_valid
      expect(runner.errors[:config].join).to include(
        "OpenCode model belongs to the InceptionLabs catalog but expected MiniMax"
      )
    end

    # @spec MODEL-POLICY-001 MODEL-POLICY-002 MODEL-POLICY-003 MODEL-POLICY-004 MODEL-POLICY-006 MODEL-POLICY-007 MODEL-POLICY-009 MODEL-POLICY-011
    describe "opencode model_policy" do
      it "defaults to specific when unset" do
        runner.runner_key = "opencode"

        expect(runner.opencode_model_policy).to eq("specific")
      end

      it "returns nil for runner keys other than opencode" do
        runner.runner_key = "cursor"

        expect(runner.opencode_model_policy).to be_nil
      end

      it "rejects an unsupported model policy value" do
        api_key = create(:provider_api_key, user: runner.user, api_service_type: "openrouter")
        create(:llm_model, model_id: "meta-llama/llama-4-maverick", provider: "openrouter", tier: "mid")
        runner.auth_type = "api_key"
        runner.provider_api_key = api_key
        runner.runner_key = "opencode"
        runner.config = { "opencode" => { "api_provider" => "openrouter", "model" => "meta-llama/llama-4-maverick", "model_policy" => "bogus" } }

        expect(runner).not_to be_valid
        expect(runner.errors[:config]).to include("must include a supported OpenCode model policy")
      end

      it "allows the free policy without a model id when the API provider is openrouter" do
        api_key = create(:provider_api_key, user: runner.user, api_service_type: "openrouter")
        runner.auth_type = "api_key"
        runner.provider_api_key = api_key
        runner.runner_key = "opencode"
        runner.assign_attributes(enabled_for_agent_runs: false, enabled_for_chat: false, enabled_for_fallback: false)
        runner.config = { "opencode" => { "api_provider" => "openrouter", "model_policy" => "free" } }

        expect(runner).to be_valid
      end

      it "rejects the free policy on a non-openrouter API provider" do
        api_key = create(:provider_api_key, user: runner.user, api_service_type: "minimax")
        runner.auth_type = "api_key"
        runner.provider_api_key = api_key
        runner.runner_key = "opencode"
        runner.config = { "opencode" => { "api_provider" => "minimax", "model_policy" => "free" } }

        expect(runner).not_to be_valid
        expect(runner.errors[:config]).to include("OpenCode free model policy requires the OpenRouter API provider")
      end

      it "still requires a model id for the specific policy" do
        api_key = create(:provider_api_key, user: runner.user, api_service_type: "openrouter")
        runner.auth_type = "api_key"
        runner.provider_api_key = api_key
        runner.runner_key = "opencode"
        runner.config = { "opencode" => { "api_provider" => "openrouter", "model_policy" => "specific", "model" => "" } }

        expect(runner).not_to be_valid
        expect(runner.errors[:config]).to include("must include an OpenCode model id")
      end

      it "rejects an unsupported model policy value on a subscription-auth runner" do
        runner.runner_key = "opencode"
        runner.config = { "opencode" => { "model_policy" => "bogus" } }

        expect(runner).not_to be_valid
        expect(runner.errors[:config]).to include("must include a supported OpenCode model policy")
      end

      it "rejects the free policy on a subscription-auth runner with a non-openrouter API provider" do
        runner.runner_key = "opencode"
        runner.config = { "opencode" => { "api_provider" => "minimax", "model_policy" => "free" } }

        expect(runner).not_to be_valid
        expect(runner.errors[:config]).to include("OpenCode free model policy requires the OpenRouter API provider")
      end

      it "treats a free-policy opencode runner as free_model_policy?" do
        runner.runner_key = "opencode"
        runner.config = { "opencode" => { "api_provider" => "openrouter", "model_policy" => "free" } }

        expect(runner).to be_free_model_policy
      end

      it "treats a specific-policy opencode runner as not free_model_policy?" do
        runner.runner_key = "opencode"
        runner.config = { "opencode" => { "api_provider" => "openrouter", "model" => "some-model" } }

        expect(runner).not_to be_free_model_policy
      end

      it "rejects crafted tier_model_ids that pin a free-policy opencode runner to a paid model" do
        user = create(:user)
        api_key = create(:provider_api_key, user: user, api_service_type: "openrouter")
        paid_model = create(:llm_model, model_id: "claude-sonnet-4-6", provider: "anthropic", tier: "mid", pricing_tier: "paid")
        free_runner = create(:runner, user: user, runner_key: "opencode", auth_type: "api_key", provider_api_key: api_key,
          enabled_for_agent_runs: false, enabled_for_chat: false, enabled_for_fallback: false,
          config: { "opencode" => { "api_provider" => "openrouter", "model_policy" => "free" } })

        free_runner.tier_model_ids = LlmModel::TIERS.index_with { paid_model.model_id }
        expect(free_runner).not_to be_valid
        expect(free_runner.errors[:tier_model_ids].join).to include("must reference free models")
      end

      it "accepts free tier_model_ids for a free-policy opencode runner" do
        user = create(:user)
        api_key = create(:provider_api_key, user: user, api_service_type: "openrouter")
        free_model = create(:llm_model, model_id: "free-mid", provider: "deepseek", tier: "mid", pricing_tier: "free")
        free_runner = create(:runner, user: user, runner_key: "opencode", auth_type: "api_key", provider_api_key: api_key,
          enabled_for_agent_runs: false, enabled_for_chat: false, enabled_for_fallback: false,
          config: { "opencode" => { "api_provider" => "openrouter", "model_policy" => "free" } })

        free_runner.tier_model_ids = LlmModel::TIERS.index_with { free_model.model_id }
        expect(free_runner).to be_valid
      end

      it "shows an OpenCode Free display name for the free policy" do
        runner.runner_key = "opencode"
        runner.config = { "opencode" => { "api_provider" => "openrouter", "model_policy" => "free" } }

        expect(runner.display_name).to eq("OpenCode Free (OpenRouter)")
      end

      it "appends the API Key suffix to the free-policy display name for api_key auth" do
        api_key = create(:provider_api_key, user: runner.user, api_service_type: "openrouter")
        runner.runner_key = "opencode"
        runner.auth_type = "api_key"
        runner.provider_api_key = api_key
        runner.config = { "opencode" => { "api_provider" => "openrouter", "model_policy" => "free" } }

        expect(runner.display_name).to eq("OpenCode Free (OpenRouter) (API Key)")
      end

      it "prevents a second free-policy runner on the same OpenRouter credential" do
        user = create(:user)
        api_key = create(:provider_api_key, user: user, api_service_type: "openrouter")
        create(:runner, user: user, runner_key: "opencode", auth_type: "api_key", provider_api_key: api_key,
          name: "Free Policy Seed", config: { "opencode" => { "api_provider" => "openrouter", "model_policy" => "free" } })

        duplicate = build(:runner, user: user, runner_key: "opencode", auth_type: "api_key", provider_api_key: api_key,
          enabled_for_agent_runs: false, enabled_for_chat: false, enabled_for_fallback: false,
          config: { "opencode" => { "api_provider" => "openrouter", "model_policy" => "free" } })

        expect(duplicate).not_to be_valid
        expect(duplicate.errors[:runner_key]).to include("already has a free-model runner for this OpenRouter credential")
      end

      it "allows free-policy runners on different OpenRouter credentials" do
        user = create(:user)
        api_key_a = create(:provider_api_key, user: user, api_service_type: "openrouter")
        api_key_b = create(:provider_api_key, user: user, api_service_type: "openrouter")
        create(:runner, user: user, runner_key: "opencode", auth_type: "api_key", provider_api_key: api_key_a,
          config: { "opencode" => { "api_provider" => "openrouter", "model_policy" => "free" } })

        second = build(:runner, user: user, runner_key: "opencode", auth_type: "api_key", provider_api_key: api_key_b,
          enabled_for_agent_runs: false, enabled_for_chat: false, enabled_for_fallback: false,
          config: { "opencode" => { "api_provider" => "openrouter", "model_policy" => "free" } })

        expect(second).to be_valid
      end

      it "allows a specific-policy opencode runner alongside an existing free-policy runner on the same credential" do
        user = create(:user)
        api_key = create(:provider_api_key, user: user, api_service_type: "openrouter")
        create(:llm_model, model_id: "moonshotai/kimi-k2-0905", provider: "openrouter", tier: "mid")
        create(:runner, user: user, runner_key: "opencode", auth_type: "api_key", provider_api_key: api_key,
          name: "Free Policy Seed", config: { "opencode" => { "api_provider" => "openrouter", "model_policy" => "free" } })

        specific = build(:runner, user: user, runner_key: "opencode", auth_type: "api_key", provider_api_key: api_key,
          config: { "opencode" => { "api_provider" => "openrouter", "model" => "moonshotai/kimi-k2-0905" } })

        expect(specific).to be_valid
      end
    end

    describe "free model policy on other direct-outbound runners" do
      %w[kilocode pi omp].each do |runner_key|
        it "allows #{runner_key} free policy without a model id when the API provider is openrouter" do # @spec MODEL-POLICY-002
          api_key = create(:provider_api_key, user: runner.user, api_service_type: "openrouter")
          runner.auth_type = "api_key"
          runner.provider_api_key = api_key
          runner.runner_key = runner_key
          runner.assign_attributes(enabled_for_agent_runs: false, enabled_for_chat: false, enabled_for_fallback: false)
          runner.config = { runner_key => { "api_provider" => "openrouter", "model_policy" => "free" } }

          expect(runner).to be_valid
          expect(runner).to be_free_model_policy
        end

        it "rejects #{runner_key} free policy on a non-openrouter API provider" do # @spec MODEL-POLICY-002
          api_key = create(:provider_api_key, user: runner.user, api_service_type: "anthropic")
          runner.auth_type = "api_key"
          runner.provider_api_key = api_key
          runner.runner_key = runner_key
          runner.config = { runner_key => { "api_provider" => "anthropic", "model_policy" => "free" } }

          expect(runner).not_to be_valid
          expect(runner.errors[:config].join).to include("free model policy requires the OpenRouter API provider")
        end

        it "requires API key auth for enabled #{runner_key} free-policy runners" do # @spec MODEL-POLICY-011
          runner.auth_type = "subscription"
          runner.runner_key = runner_key
          runner.config = { runner_key => { "api_provider" => "openrouter", "model_policy" => "free" } }

          expect(runner).not_to be_valid
          expect(runner.errors[:auth_type]).to include("must be API key for the free model policy")
        end
      end

      it "still requires a model id for kilocode specific policy" do # @spec MODEL-POLICY-003
        api_key = create(:provider_api_key, user: runner.user, api_service_type: "openrouter")
        runner.auth_type = "api_key"
        runner.provider_api_key = api_key
        runner.runner_key = "kilocode"
        runner.config = { "kilocode" => { "api_provider" => "openrouter", "model_policy" => "specific", "model" => "" } }

        expect(runner).not_to be_valid
        expect(runner.errors[:config].join).to include("KiloCode model id")
      end

      %w[pi omp].each do |runner_key|
        it "keeps the #{runner_key} model optional for specific policy" do # @spec MODEL-POLICY-003
          api_key = create(:provider_api_key, user: runner.user, api_service_type: "openrouter")
          runner.auth_type = "api_key"
          runner.provider_api_key = api_key
          runner.runner_key = runner_key
          runner.config = { runner_key => { "api_provider" => "openrouter", "model_policy" => "specific", "model" => "" } }

          expect(runner).to be_valid
        end
      end
    end

    describe "agent_co_author_trailer" do
      it "allows a normal single-line trailer" do
        runner.agent_co_author_trailer = "Co-Authored-By: Claude <noreply@anthropic.com>"
        expect(runner).to be_valid
      end

      it "allows blank trailer" do
        runner.agent_co_author_trailer = ""
        expect(runner).to be_valid
      end

      it "allows nil trailer" do
        runner.agent_co_author_trailer = nil
        expect(runner).to be_valid
      end

      it "rejects trailer containing newline" do
        runner.agent_co_author_trailer = "Co-Authored-By: A\nCo-Authored-By: B"
        expect(runner).not_to be_valid
        expect(runner.errors[:agent_co_author_trailer]).to include("must be a single line (no newlines)")
      end

      it "rejects trailer containing carriage return" do
        runner.agent_co_author_trailer = "Co-Authored-By: A\rB"
        expect(runner).not_to be_valid
        expect(runner.errors[:agent_co_author_trailer]).to include("must be a single line (no newlines)")
      end

      it "strips leading and trailing whitespace before validation" do
        runner.agent_co_author_trailer = "  Co-Authored-By: Claude <noreply@anthropic.com>  "
        runner.valid?
        expect(runner.agent_co_author_trailer).to eq("Co-Authored-By: Claude <noreply@anthropic.com>")
      end

      it "normalizes whitespace-only values to nil" do
        runner.agent_co_author_trailer = "   "
        runner.valid?
        expect(runner.agent_co_author_trailer).to be_nil
      end
    end
  end

  describe "scopes" do
    let(:user) { create(:user) }

    it ".subscription returns only subscription runners" do
      sub = user.runners.find_by(runner_key: "claude")
      api_key = create(:provider_api_key, user: user, api_service_type: "anthropic")
      api = user.runners.create!(runner_key: "claude", auth_type: "api_key", provider_api_key: api_key)

      expect(described_class.subscription).to include(sub)
      expect(described_class.subscription).not_to include(api)
    end

    it ".api_key returns only api_key providers" do
      sub = user.runners.find_by(runner_key: "claude")
      api_key = create(:provider_api_key, user: user, api_service_type: "anthropic")
      api = user.runners.create!(runner_key: "claude", auth_type: "api_key", provider_api_key: api_key)

      expect(described_class.api_key).to include(api)
      expect(described_class.api_key).not_to include(sub)
    end
  end

  describe ".supported_runner_keys" do
    it "returns app runner keys backed by the agent harness registry" do
      expect(described_class.supported_runner_keys).to include("claude", "cursor", "gemini", "codex", "kilocode", "copilot")
      expect(described_class.supported_runner_keys).not_to include("github_copilot")
    end
  end

  describe ".addable_runner_keys" do
    it "returns only providers installed in paid-agent" do
      expect(described_class.addable_runner_keys).to match_array(RunnerSupport.addable_runner_keys)
    end
  end

  describe ".harness_runner_key_for" do
    it "maps app runner keys to agent harness runner keys" do
      expect(described_class.harness_runner_key_for("copilot")).to eq("github_copilot")
      expect(described_class.harness_runner_key_for("gemini")).to eq("gemini")
      expect(described_class.harness_runner_key_for("omp")).to eq("omp")
    end
  end

  describe ".agent_type_for" do
    it "maps runner keys to app agent types" do
      expect(described_class.agent_type_for("claude")).to eq("claude_code")
      expect(described_class.agent_type_for("copilot")).to eq("copilot")
    end
  end

  describe ".runner_key_for_agent_type" do
    it "maps app agent types back to runner keys" do
      expect(described_class.runner_key_for_agent_type("claude_code")).to eq("claude")
      expect(described_class.runner_key_for_agent_type("copilot")).to eq("copilot")
    end
  end

  describe ".ensure_default_for" do
    let(:user) { create(:user) }

    it "creates the default runner when missing" do
      user.runners.delete_all
      default_key = described_class.default_runner_key

      expect { described_class.ensure_default_for(user) }
        .to change { user.runners.where(runner_key: default_key).count }
        .from(0).to(1)
    end

    it "creates a subscription runner by default" do
      user.runners.delete_all
      default_key = described_class.default_runner_key

      described_class.ensure_default_for(user)
      runner = user.runners.find_by(runner_key: default_key)

      expect(runner.auth_type).to eq("subscription")
    end

    it "is idempotent" do
      default_key = described_class.default_runner_key

      expect { described_class.ensure_default_for(user) }
        .not_to change { user.runners.where(runner_key: default_key).count }
    end

    it "resets the runners sequence and retries on primary key conflicts" do
      default_key = described_class.default_runner_key
      relation = user.runners.kept_only
      conflict = ActiveRecord::RecordNotUnique.new
      calls = 0
      connection = instance_double(ActiveRecord::ConnectionAdapters::PostgreSQLAdapter, reset_pk_sequence!: true)

      allow(user.runners).to receive(:kept_only).and_return(relation)
      allow(relation).to receive(:find_or_create_by!).and_wrap_original do |original, *args, **kwargs|
        calls += 1
        raise conflict if calls == 1

        original.call(*args, **kwargs)
      end
      allow(described_class).to receive(:connection).and_return(connection)
      allow(described_class).to receive(:primary_key_conflict?).with(conflict).and_return(true)

      described_class.ensure_default_for(user)

      expect(connection).to have_received(:reset_pk_sequence!).with("runners")
      expect(relation).to have_received(:find_or_create_by!)
        .with(runner_key: default_key, auth_type: "subscription").twice
    end
  end

  describe ".display_name" do
    it "uses agent harness runner display names when available" do
      expect(described_class.display_name("codex")).to eq("OpenAI Codex CLI")
      expect(described_class.display_name("copilot")).to eq("GitHub Copilot CLI")
      expect(described_class.display_name("omp")).to eq("Oh My Pi")
    end

    it "falls back to titleized keys for unknown runners" do
      expect(described_class.display_name("unknown_provider")).to eq("Unknown Provider")
    end
  end

  describe ".for_identifier" do
    let(:user) { create(:user) }

    it "prefers the subscription entry for plain runner keys" do
      subscription = user.runners.find_by!(runner_key: "claude")
      api_key = create(:provider_api_key, user: user, api_service_type: "anthropic")
      user.runners.create!(runner_key: "claude", auth_type: "api_key", provider_api_key: api_key)

      expect(described_class.for_identifier(user, "claude")).to eq(subscription)
    end

    it "prefers kept rows before discarded rows when including discarded matches" do
      discarded_subscription = create(:runner, user: user, runner_key: "opencode", name: "Legacy Name")
      discarded_subscription.update_column(:discarded_at, Time.current)
      kept_subscription = create(:runner, user: user, runner_key: "opencode", name: "Current Name")

      expect(described_class.for_identifier(user, "opencode", include_discarded: true)).to eq(kept_subscription)
    end

    it "resolves legacy provider routing-key identifiers during the phase-1 bridge" do
      subscription = user.runners.find_by!(runner_key: "claude")

      expect(described_class.for_identifier(user, "provider:#{subscription.id}")).to eq(subscription)
    end
  end

  describe "#display_name" do
    it "uses custom name when set" do
      runner = build(:runner, name: "My Custom Provider")

      expect(runner.display_name).to eq("My Custom Provider")
    end

    it "uses titleized runner_key for subscription" do
      runner = build(:runner, runner_key: "claude", auth_type: "subscription")

      expect(runner.display_name).to eq(described_class.display_name_for("claude"))
    end

    it "appends (API Key) for api_key auth type" do
      runner = build(:runner, runner_key: "claude", auth_type: "api_key", name: nil)

      expect(runner.display_name).to eq("#{described_class.display_name_for("claude")} (API Key)")
    end

    it "includes the model id for unnamed OpenCode entries" do
      runner = build(
        :runner,
        runner_key: "opencode",
        auth_type: "api_key",
        name: nil,
        config: { "opencode" => { "api_provider" => "openrouter", "model" => "moonshotai/kimi-k2-0905" } }
      )

      expect(runner.display_name).to eq("#{described_class.display_name_for("opencode")} moonshotai/kimi-k2-0905 (API Key)")
    end

    it "includes the model id for unnamed Oh My Pi entries" do
      runner = build(
        :runner,
        runner_key: "omp",
        auth_type: "api_key",
        name: nil,
        config: { "omp" => { "api_provider" => "deepseek", "model" => "deepseek-chat" } }
      )

      expect(runner.display_name).to eq("Oh My Pi deepseek-chat (API Key)")
    end
  end

  # @spec MODEL-POLICY-006
  describe "runner-option cache invalidation for opencode model_policy changes" do
    it "invalidates the cache when model_policy flips without changing model" do
      api_key = create(:provider_api_key, api_service_type: "openrouter")
      create(:llm_model, :free, model_id: "meta-llama/llama-4-maverick", tier: "mid")
      runner = create(
        :runner,
        user: api_key.user,
        runner_key: "opencode",
        auth_type: "api_key",
        provider_api_key: api_key,
        enabled_for_agent_runs: false,
        enabled_for_chat: false,
        enabled_for_fallback: false,
        config: { "opencode" => { "api_provider" => "openrouter", "model" => "meta-llama/llama-4-maverick" } }
      )

      expect(AgentRun).to receive(:invalidate_runner_options_cache).with(account_id: api_key.user.account_id)

      runner.update!(config: { "opencode" => { "api_provider" => "openrouter", "model" => "meta-llama/llama-4-maverick", "model_policy" => "free" } })
    end
  end

  describe "KiloCode config generation" do
    let(:account) { create(:account, slug: "runner-kilocode-#{SecureRandom.hex(6)}") }
    let(:user) { create(:user, account: account, email: "runner-kilocode-#{SecureRandom.hex(6)}@example.com") }
    let(:api_key) { create(:provider_api_key, user: user, api_service_type: "anthropic") }
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
    let(:runner) do
      create(
        :runner,
        user: user,
        runner_key: "kilocode",
        auth_type: "api_key",
        provider_api_key: api_key,
        config: { "kilocode" => { "api_provider" => "anthropic", "model" => "claude-sonnet-4-20250514" } }
      )
    end

    before do
      create(:llm_model, model_id: "claude-sonnet-4-20250514", provider: "anthropic", tier: "mid")
      create(:llm_model, model_id: "anthropic/claude-opus-4", provider: "anthropic", tier: "high")
      create(:llm_model, model_id: "glm-5.1", provider: "zai_coding", tier: "mid")
    end

    it "generates runner as a record with prefixed model" do
      config = JSON.parse(runner.kilocode_config_json)

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
      expect(config["permission"]).to eq({
        "external_directory" => {
          "/home/agent/**" => "allow",
          "/tmp/**" => "allow",
          "/usr/local/lib/ruby/gems/*/gems/agent-harness-*/**" => "allow"
        }
      })
    end

    it "does not double-prefix already-qualified model ids" do
      runner.update!(config: { "kilocode" => { "api_provider" => "anthropic", "model" => "anthropic/claude-opus-4" } })

      config = JSON.parse(runner.kilocode_config_json)

      expect(config["model"]).to eq("anthropic/claude-opus-4")
    end

    it "reads an optional per-runner preflight timeout override from config" do
      runner.update!(
        config: { "kilocode" => { "api_provider" => "anthropic", "model" => "claude-sonnet-4-20250514", "preflight_timeout_seconds" => "45" } }
      )

      expect(runner.kilocode_preflight_timeout_seconds).to eq(45)
    end

    it "exposes the kilocode timeout via runner_preflight_timeout_seconds" do
      runner.update!(
        config: { "kilocode" => { "api_provider" => "anthropic", "model" => "claude-sonnet-4-20250514", "preflight_timeout_seconds" => "45" } }
      )

      expect(runner.runner_preflight_timeout_seconds).to eq(45)
    end

    context "with a z.ai coding-plan backend" do
      before do
        zai_key = create(:provider_api_key, user: user, api_service_type: "zai_coding")
        runner.update!(
          provider_api_key: zai_key,
          config: { "kilocode" => { "api_provider" => "zai_coding", "model" => "glm-5.1" } }
        )
      end

      it "uses the native zai-coding-plan runner id for z.ai coding plan backends" do
        config = JSON.parse(runner.kilocode_config_json)

        expect(config["provider"]).to eq({
          "zai-coding-plan" => {
            "options" => {
              "apiKey" => "{env:ZHIPU_API_KEY}",
              "baseURL" => "https://api.z.ai/api/coding/paas/v4"
            },
            "models" => {
              "glm-5.1" => expected_zai_model_entry
            }
          }
        })
      end

      it "qualifies the z.ai coding-plan model id" do
        config = JSON.parse(runner.kilocode_config_json)

        expect(config["model"]).to eq("zai-coding-plan/glm-5.1")
      end

      it "keeps the upstream KiloCode defaults plus the Paid harness gem path" do
        config = JSON.parse(runner.kilocode_config_json)

        expect(config["permission"]).to eq({
          "external_directory" => {
            "/home/agent/**" => "allow",
            "/tmp/**" => "allow",
            "/usr/local/lib/ruby/gems/*/gems/agent-harness-*/**" => "allow"
          }
        })
      end
    end
  end

  describe "Oh My Pi config infrastructure" do
    let(:account) { create(:account, slug: "runner-omp-#{SecureRandom.hex(6)}") }
    let(:user) { create(:user, account: account, email: "runner-omp-#{SecureRandom.hex(6)}@example.com") }
    let(:api_key) { create(:provider_api_key, user: user, api_service_type: "deepseek", api_key: "sk-omp-test") }

    it "reads OMP config accessors from the config hash" do
      runner = build(
        :runner,
        user: user,
        runner_key: "omp",
        auth_type: "api_key",
        provider_api_key: api_key,
        config: { "omp" => { "api_provider" => "deepseek", "model" => "deepseek-chat" } }
      )

      expect(runner.omp_api_provider).to eq("deepseek")
      expect(runner.omp_model_id).to eq("deepseek-chat")
      expect(runner.omp_required_api_service_type).to eq("deepseek")
    end

    it "defaults api_provider to deepseek when unset" do
      runner = build(:runner, runner_key: "omp", auth_type: "api_key",
        user: user, provider_api_key: api_key, config: { "omp" => { "model" => "deepseek-chat" } })

      expect(runner.omp_api_provider).to eq("deepseek")
    end

    it "builds an agent-harness runtime with the backend API key in env" do
      runner = build(
        :runner,
        user: user,
        runner_key: "omp",
        auth_type: "api_key",
        provider_api_key: api_key,
        config: { "omp" => { "api_provider" => "deepseek", "model" => "deepseek-chat" } }
      )

      runtime = runner.agent_harness_runner_runtime

      expect(runtime.model).to eq("deepseek-chat")
      expect(runtime.api_provider).to eq("deepseek")
      expect(runtime.env).to eq("DEEPSEEK_API_KEY" => "sk-omp-test")
    end
  end

  describe "derived direct-outbound api providers" do
    let(:account) { create(:account, slug: "derived-provider-#{SecureRandom.hex(6)}") }
    let(:user) { create(:user, account: account, email: "derived-provider-#{SecureRandom.hex(6)}@example.com") }

    # @spec DIRECT-OUTBOUND-CATALOG-008
    it "derives the OpenCode api provider from the selected API key and ignores a stale stored value" do
      api_key = create(:provider_api_key, user: user, api_service_type: "anthropic")
      create(:llm_model, model_id: "claude-sonnet-4-20250514", provider: "anthropic", tier: "mid")

      runner = build(
        :runner,
        user: user,
        runner_key: "opencode",
        auth_type: "api_key",
        provider_api_key: api_key,
        config: { "opencode" => { "api_provider" => "openrouter", "model" => "claude-sonnet-4-20250514" } }
      )

      expect(runner.opencode_api_provider).to eq("anthropic")
      expect(runner).to be_valid
    end

    # @spec DIRECT-OUTBOUND-CATALOG-008
    it "keeps honoring the legacy OpenCode config value when no provider_api_key is present" do
      runner = build(
        :runner,
        user: user,
        runner_key: "opencode",
        auth_type: "api_key",
        provider_api_key: nil,
        config: { "opencode" => { "api_provider" => "minimax", "model" => "MiniMax-M3" } }
      )

      expect(runner.opencode_api_provider).to eq("minimax")
    end

    # @spec DIRECT-OUTBOUND-CATALOG-008
    it "does not default a new record's api provider before a key is selected" do
      runner = build(
        :runner,
        user: user,
        runner_key: "opencode",
        auth_type: "api_key",
        provider_api_key: nil,
        config: {}
      )

      expect(runner.opencode_api_provider).to be_nil
      expect(runner.opencode_required_api_service_type).to be_nil
    end

    # @spec DIRECT-OUTBOUND-CATALOG-008
    it "falls back to the default provider for a persisted record with no key or legacy value" do
      api_key = create(:provider_api_key, user: user, api_service_type: "anthropic")
      create(:llm_model, model_id: "claude-sonnet-4-20250514", provider: "anthropic", tier: "mid")
      runner = create(
        :runner,
        user: user,
        runner_key: "opencode",
        auth_type: "api_key",
        provider_api_key: api_key,
        config: { "opencode" => { "model" => "claude-sonnet-4-20250514" } }
      )
      runner.provider_api_key = nil

      expect(runner.opencode_api_provider).to eq(Runner::OPENCODE_DEFAULT_API_PROVIDER)
    end

    # @spec DIRECT-OUTBOUND-CATALOG-008
    it "validates the selected model against the provider derived from the API key" do
      api_key = create(:provider_api_key, user: user, api_service_type: "anthropic")
      create(:llm_model, model_id: "moonshotai/kimi-k2-0905", provider: "openrouter", tier: "mid")

      runner = build(
        :runner,
        user: user,
        runner_key: "opencode",
        auth_type: "api_key",
        provider_api_key: api_key,
        config: { "opencode" => { "api_provider" => "openrouter", "model" => "moonshotai/kimi-k2-0905" } }
      )

      expect(runner).not_to be_valid
      expect(runner.errors[:config].join).to include("expected Anthropic")
    end

    # @spec DIRECT-OUTBOUND-CATALOG-008
    it "derives the Pi provider from the selected API key" do
      deepseek_key = create(:provider_api_key, user: user, api_service_type: "deepseek")
      create(:llm_model, model_id: "deepseek-chat", provider: "deepseek", tier: "mid")

      pi_runner = build(
        :runner,
        user: user,
        runner_key: "pi",
        auth_type: "api_key",
        provider_api_key: deepseek_key,
        config: { "pi" => { "api_provider" => "minimax", "model" => "deepseek-chat" } }
      )
      expect(pi_runner.pi_api_provider).to eq("deepseek")
      expect(pi_runner).to be_valid
    end

    it "derives the Oh My Pi provider from the selected API key" do
      deepseek_key = create(:provider_api_key, user: user, api_service_type: "deepseek")
      create(:llm_model, model_id: "deepseek-chat", provider: "deepseek", tier: "mid")

      omp_runner = build(
        :runner,
        user: user,
        runner_key: "omp",
        auth_type: "api_key",
        provider_api_key: deepseek_key,
        config: { "omp" => { "api_provider" => "minimax", "model" => "deepseek-chat" } }
      )

      expect(omp_runner.omp_api_provider).to eq("deepseek")
      expect(omp_runner).to be_valid
    end
  end

  describe "sync_direct_outbound_tier_models callback" do
    let(:account) { create(:account, slug: "sync-tier-#{SecureRandom.hex(6)}") }
    let(:user) { create(:user, account: account, email: "sync-tier-#{SecureRandom.hex(6)}@example.com") }
    let(:api_key) { create(:provider_api_key, user: user, api_service_type: "openrouter") }

    # @spec MODEL-POLICY-005
    it "seeds tier_model_ids from active free models for a free-policy opencode runner" do
      create(:llm_model, model_id: "opencode-free-low", provider: "deepseek", tier: "low", pricing_tier: "free", capability_score: 4.0,
        catalog_source: "openrouter_sync")
      create(:llm_model, model_id: "opencode-free-mid", provider: "moonshotai", tier: "mid", pricing_tier: "free", capability_score: 6.0,
        catalog_source: "openrouter_sync")
      create(:llm_model, model_id: "opencode-free-high", provider: "qwen", tier: "high", pricing_tier: "free", capability_score: 8.0,
        catalog_source: "openrouter_sync")

      runner = create(
        :runner,
        user: user,
        runner_key: "opencode",
        auth_type: "api_key",
        provider_api_key: api_key,
        enabled_for_agent_runs: false, enabled_for_chat: false, enabled_for_fallback: false,
        config: { "opencode" => { "api_provider" => "openrouter", "model_policy" => "free" } }
      )

      expect(runner.tier_model_ids).to eq(
        "low" => "opencode-free-low",
        "mid" => "opencode-free-mid",
        "high" => "opencode-free-high"
      )
    end

    # @spec MODEL-POLICY-005
    it "preserves tier_model_ids for a free-policy opencode runner on unrelated saves" do
      free_model = create(:llm_model, model_id: "opencode-free-mid-2", provider: "deepseek", tier: "mid", pricing_tier: "free",
        catalog_source: "openrouter_sync")
      runner = create(
        :runner,
        user: user,
        runner_key: "opencode",
        auth_type: "api_key",
        provider_api_key: api_key,
        enabled_for_agent_runs: false, enabled_for_chat: false, enabled_for_fallback: false,
        config: { "opencode" => { "api_provider" => "openrouter", "model_policy" => "free" } },
        tier_model_ids: { "mid" => free_model.model_id }
      )

      runner.update!(name: "Renamed Free Runner")

      expect(runner.reload.tier_model_ids).to eq("mid" => free_model.model_id)
    end

    it "clears stale tier_model_ids when runner no longer qualifies for direct-outbound" do
      create(:llm_model, model_id: "test-model-1", provider: "openrouter", tier: "mid")
      runner = create(
        :runner,
        user: user,
        runner_key: "opencode",
        auth_type: "api_key",
        provider_api_key: api_key,
        config: { "opencode" => { "api_provider" => "openrouter", "model" => "test-model-1" } }
      )

      expect(runner.tier_model_ids).to be_present

      runner.update_columns(config: { "opencode" => { "api_provider" => "openrouter" } })

      runner.valid?
      expect(runner.tier_model_ids).to be_blank
    end

    it "clears stale tier_model_ids when model is removed from config" do
      create(:llm_model, model_id: "test-model-2", provider: "openrouter", tier: "mid")
      runner = create(
        :runner,
        user: user,
        runner_key: "kilocode",
        auth_type: "api_key",
        provider_api_key: api_key,
        config: { "kilocode" => { "api_provider" => "openrouter", "model" => "test-model-2" } }
      )

      expect(runner.tier_model_ids).to be_present

      runner.update_columns(config: { "kilocode" => { "api_provider" => "openrouter", "model" => "" } })

      runner.valid?
      expect(runner.tier_model_ids).to be_blank
    end

    it "clears stale tier_model_ids when the Pi model is removed from config" do
      minimax_key = create(:provider_api_key, user: user, api_service_type: "minimax")
      create(:llm_model, model_id: "MiniMax-M2.7", provider: "minimax", tier: "mid")
      runner = create(
        :runner,
        user: user,
        runner_key: "pi",
        auth_type: "api_key",
        provider_api_key: minimax_key,
        config: { "pi" => { "api_provider" => "minimax", "model" => "MiniMax-M2.7" } }
      )

      expect(runner.tier_model_ids).to be_present

      runner.update_columns(config: { "pi" => { "api_provider" => "minimax", "model" => "" } })

      runner.valid?
      expect(runner.tier_model_ids).to be_blank
    end

    it "preserves tier_model_ids on unrelated attribute saves when config is unchanged" do
      create(:llm_model, model_id: "test-model-3", provider: "openrouter", tier: "mid")
      runner = create(
        :runner,
        user: user,
        runner_key: "opencode",
        auth_type: "api_key",
        provider_api_key: api_key,
        config: { "opencode" => { "api_provider" => "openrouter", "model" => "test-model-3" } }
      )

      original_tier_model_ids = runner.tier_model_ids.dup
      runner.update!(name: "Renamed Provider")

      expect(runner.reload.tier_model_ids).to eq(original_tier_model_ids)
    end

    it "updates tier_model_ids when the configured model changes" do
      create(:llm_model, model_id: "test-model-old", provider: "openrouter", tier: "mid")
      create(:llm_model, model_id: "test-model-new", provider: "openrouter", tier: "mid")
      runner = create(
        :runner,
        user: user,
        runner_key: "opencode",
        auth_type: "api_key",
        provider_api_key: api_key,
        config: { "opencode" => { "api_provider" => "openrouter", "model" => "test-model-old" } }
      )

      runner.update!(config: { "opencode" => { "api_provider" => "openrouter", "model" => "test-model-new" } })

      expect(runner.reload.tier_model_ids.values.uniq).to eq([ "test-model-new" ])
    end

    it "reactivates an inactive LlmModel when reused for a direct-outbound runner" do
      inactive_model = create(:llm_model, model_id: "inactive-test-model", provider: "openrouter", tier: "mid", active: false)

      runner = create(
        :runner,
        user: user,
        runner_key: "opencode",
        auth_type: "api_key",
        provider_api_key: api_key,
        config: { "opencode" => { "api_provider" => "openrouter", "model" => "inactive-test-model" } }
      )

      expect(inactive_model.reload).to be_active
      expect(runner.tier_model_ids.values.uniq).to eq([ "inactive-test-model" ])
    end

    it "normalizes provider-qualified OpenCode tier models back to the catalog model id" do
      minimax_key = create(:provider_api_key, user: user, api_service_type: "minimax")
      create(:llm_model, model_id: "MiniMax-M3", provider: "minimax", tier: "mid")

      runner = create(
        :runner,
        user: user,
        runner_key: "opencode",
        auth_type: "api_key",
        provider_api_key: minimax_key,
        config: { "opencode" => { "api_provider" => "minimax", "model" => "minimax/MiniMax-M3" } }
      )

      expect(runner.tier_model_ids.values.uniq).to eq([ "MiniMax-M3" ])
    end
  end

  describe "OpenCode agent-harness runtime helpers" do
    let(:user) { create(:user) }
    let(:api_key) { create(:provider_api_key, user: user, api_service_type: "openrouter", api_key: "sk-openrouter-secret") }
    let(:runner) do
      create(
        :runner,
        user: user,
        runner_key: "opencode",
        auth_type: "api_key",
        provider_api_key: api_key,
        config: { "opencode" => { "api_provider" => "openrouter", "model" => "moonshotai/kimi-k2-0905" } }
      )
    end

    before do
      create(:llm_model, model_id: "moonshotai/kimi-k2-0905", provider: "openrouter", tier: "mid")
      create(:llm_model, model_id: "glm-5.1", provider: "zai_coding", tier: "mid")
      create(:llm_model, model_id: "glm-5.1-zai", provider: "zai", tier: "mid")
      create(:llm_model, model_id: "MiniMax-M2.7", provider: "minimax", tier: "mid")
      create(:llm_model, model_id: "MiniMax-M2.7-highspeed", provider: "minimax", tier: "mid")
      create(:llm_model, model_id: "MiniMax-M3", provider: "minimax", tier: "high")
      create(:llm_model, model_id: "claude-sonnet-4-5", provider: "anthropic", tier: "mid")
    end

    def expected_minimax_provider(model_id)
      { "minimax" => {
        "npm" => "@ai-sdk/anthropic",
        "models" => { model_id => { "name" => model_id } }
      } }
    end

    def expected_zai_coding_plan_provider(model_id)
      # Models-only declaration: extends opencode's built-in zai-coding-plan
      # provider (which owns baseURL/auth/native request format) with a model
      # its catalog lacks (glm-5.x). Do NOT override npm/options — that replaces
      # the built-in and sends requests z.ai rejects with a 500.
      { "zai-coding-plan" => { "models" => { model_id => { "name" => model_id } } } }
    end

    def create_opencode_runner(api_provider:, api_service_type:, api_key:, model:)
      provider_api_key = create(:provider_api_key, user: user, api_service_type: api_service_type, api_key: api_key)
      create(
        :runner,
        user: user,
        runner_key: "opencode",
        auth_type: "api_key",
        provider_api_key: provider_api_key,
        config: { "opencode" => { "api_provider" => api_provider, "model" => model } }
      )
    end

    def create_free_policy_direct_outbound_runner(runner_key:, model_id:, provider_api_key: api_key)
      create(
        :runner,
        user: user,
        runner_key: runner_key,
        auth_type: "api_key",
        provider_api_key: provider_api_key,
        enabled_for_agent_runs: false, enabled_for_chat: false, enabled_for_fallback: false,
        config: { runner_key => { "api_provider" => "openrouter", "model_policy" => "free" } },
        tier_model_ids: { "mid" => model_id }
      )
    end

    def expect_unset_env(runtime, *keys)
      expect(runtime.unset_env).to include(*keys)
    end

    def expect_minimax_runtime(runtime, model:, api_key:)
      expect(runtime.model).to eq("minimax/#{model}")
      expect(runtime.env).to include(
        "ANTHROPIC_API_KEY" => api_key,
        "ANTHROPIC_BASE_URL" => "https://api.minimax.io/anthropic/v1"
      )
      expect(runtime.env).not_to have_key("OPENAI_BASE_URL")
      expect(runtime.metadata[:config]["provider"]).to eq(expected_minimax_provider(model))
    end

    it "builds runner runtime inputs instead of a local bootstrap wrapper" do # @spec AGENT-HARNESS-004
      runtime = runner.agent_harness_runner_runtime

      expect(runtime.model).to eq("openrouter/moonshotai/kimi-k2-0905")
      expect(runtime.api_provider).to be_nil
      expect(runtime.base_url).to be_nil
      expect(runtime.env).to include(
        "OPENROUTER_API_KEY" => "sk-openrouter-secret",
        "OPENAI_BASE_URL" => "https://openrouter.ai/api/v1"
      )
      expect_unset_env(
        runtime,
        "OPENAI_API_KEY",
        "OPENAI_HEADER_X_AGENT_RUN_ID",
        "OPENAI_HEADER_X_PROXY_TOKEN",
        "ANTHROPIC_API_KEY",
        "GEMINI_API_KEY",
        "GEMINI_CLI_CUSTOM_HEADERS"
      )
      expect(runtime.metadata[:config]).not_to have_key("provider")
    end

    it "extends opencode's built-in zai-coding-plan provider with the configured glm model" do
      runtime = create_opencode_runner(
        api_provider: "zai_coding",
        api_service_type: "zai_coding",
        api_key: "sk-zai-secret",
        model: "glm-5.1"
      ).agent_harness_runner_runtime

      # opencode's built-in provider id is hyphenated; glm-5.x is declared as an
      # extension to that built-in provider (its catalog tops out at glm-4.x).
      # No npm/options override and no OPENAI_BASE_URL — the built-in provider
      # owns baseURL/auth/native request format; overriding it makes z.ai 500.
      expect(runtime.model).to eq("zai-coding-plan/glm-5.1")
      expect(runtime.env).to include("ZHIPU_API_KEY" => "sk-zai-secret")
      expect(runtime.env).not_to have_key("OPENAI_BASE_URL")
      expect(runtime.metadata[:config]["provider"]).to eq(expected_zai_coding_plan_provider("glm-5.1"))
      expect_unset_env(
        runtime,
        "OPENAI_API_KEY",
        "OPENAI_BASE_URL",
        "OPENAI_HEADER_X_AGENT_RUN_ID",
        "OPENAI_HEADER_X_PROXY_TOKEN",
        "ANTHROPIC_API_KEY",
        "GEMINI_API_KEY",
        "GEMINI_CLI_CUSTOM_HEADERS"
      )
    end

    it "qualifies zai models with runner prefix" do
      runtime = create_opencode_runner(
        api_provider: "zai",
        api_service_type: "zai",
        api_key: "sk-zai-secret",
        model: "glm-5.1-zai"
      ).agent_harness_runner_runtime

      expect(runtime.model).to eq("zai/glm-5.1-zai")
    end

    it "configures MiniMax through the Anthropic SDK provider config" do # @spec AGENT-HARNESS-004
      runtime = create_opencode_runner(
        api_provider: "minimax",
        api_service_type: "minimax",
        api_key: "sk-minimax-secret",
        model: "MiniMax-M2.7"
      ).agent_harness_runner_runtime

      expect_minimax_runtime(runtime, model: "MiniMax-M2.7", api_key: "sk-minimax-secret")
      # Paid proxy headers must be stripped so the per-run token never reaches MiniMax.
      expect_unset_env(
        runtime,
        "OPENAI_API_KEY",
        "OPENAI_BASE_URL",
        "ANTHROPIC_HEADER_X_AGENT_RUN_ID",
        "ANTHROPIC_HEADER_X_PROXY_TOKEN",
        "GEMINI_API_KEY",
        "GEMINI_CLI_CUSTOM_HEADERS"
      )
    end

    it "configures the native Anthropic provider through the @ai-sdk/anthropic SDK" do
      runtime = create_opencode_runner(
        api_provider: "anthropic",
        api_service_type: "anthropic",
        api_key: "sk-ant-secret",
        model: "claude-sonnet-4-5"
      ).agent_harness_runner_runtime

      expect(runtime.model).to eq("anthropic/claude-sonnet-4-5")
      expect(runtime.env).to include("ANTHROPIC_API_KEY" => "sk-ant-secret", "ANTHROPIC_BASE_URL" => "https://api.anthropic.com")
      expect(runtime.env).not_to have_key("OPENAI_BASE_URL")
      expect(runtime.metadata[:config]["provider"]).to eq({ "anthropic" => { "npm" => "@ai-sdk/anthropic" } })
      expect_unset_env(
        runtime,
        "OPENAI_API_KEY",
        "OPENAI_BASE_URL",
        "ANTHROPIC_HEADER_X_AGENT_RUN_ID",
        "ANTHROPIC_HEADER_X_PROXY_TOKEN",
        "GEMINI_API_KEY",
        "GEMINI_CLI_CUSTOM_HEADERS"
      )
    end

    it "qualifies MiniMax highspeed models with the minimax provider prefix" do
      runtime = create_opencode_runner(
        api_provider: "minimax",
        api_service_type: "minimax",
        api_key: "sk-minimax-hs",
        model: "MiniMax-M2.7-highspeed"
      ).agent_harness_runner_runtime

      expect_minimax_runtime(runtime, model: "MiniMax-M2.7-highspeed", api_key: "sk-minimax-hs")
    end

    it "declares newly released MiniMax models so opencode accepts them" do
      minimax_key = create(:provider_api_key, user: user, api_service_type: "minimax", api_key: "sk-minimax-secret")
      minimax_runner = create(
        :runner,
        user: user,
        runner_key: "opencode",
        auth_type: "api_key",
        provider_api_key: minimax_key,
        config: { "opencode" => { "api_provider" => "minimax", "model" => "MiniMax-M3" } }
      )

      runtime = minimax_runner.agent_harness_runner_runtime

      # The bare model id is the opencode config models key; the runtime model
      # string carries the provider prefix opencode parses into getModel.
      expect(runtime.model).to eq("minimax/MiniMax-M3")
      expect(runtime.metadata[:config]["provider"]).to eq(expected_minimax_provider("MiniMax-M3"))
    end

    it "does not enable direct outbound when the OpenCode model id is missing" do
      runner = build(
        :runner,
        user: user,
        runner_key: "opencode",
        auth_type: "api_key",
        provider_api_key: api_key,
        config: { "opencode" => { "api_provider" => "openrouter" } }
      )

      expect(runner.requires_direct_outbound?).to be(false)
      expect(runner.direct_outbound_exec_env).to eq({})
      expect(runner.direct_outbound_exec_command(command_prefix: %w[opencode run], prompt: "ping")).to eq(%w[opencode run ping])
      expect(runner.agent_harness_runner_runtime).to be_nil
    end

    it "resolves a free-policy KiloCode runtime for config-blind dispatch paths" do # @spec MODEL-POLICY-011
      free_model = create(:llm_model, model_id: "deepseek/deepseek-v4-flash:free", provider: "deepseek", tier: "mid", pricing_tier: "free",
        catalog_source: "openrouter_sync")
      free_runner = create_free_policy_direct_outbound_runner(runner_key: "kilocode", model_id: free_model.model_id)

      runtime = free_runner.agent_harness_runner_runtime

      expect(runtime.model).to eq("openai-compatible/deepseek/deepseek-v4-flash:free")
      expect(runtime.metadata[:config]["provider"]).to include(
        "openai-compatible" => hash_including(
          "models" => include(
            "deepseek/deepseek-v4-flash:free" => hash_including("id" => "deepseek/deepseek-v4-flash:free")
          )
        )
      )
    end

    it "raises a clear error when a free-policy KiloCode runner has no resolvable model" do # @spec MODEL-POLICY-011
      create(:llm_model, model_id: "placeholder", provider: "deepseek", tier: "mid", pricing_tier: "free",
        catalog_source: "openrouter_sync")
      free_runner = create_free_policy_direct_outbound_runner(runner_key: "kilocode", model_id: "placeholder")
      free_runner.update_columns(tier_model_ids: {})

      allow(Runners::ResolveTierModel).to receive(:call).and_return(
        Runners::ResolveTierModel::Result.new(error: "no model configured")
      )

      expect do
        free_runner.agent_harness_runner_runtime
      end.to raise_error(ArgumentError, /kilocode runner has no resolvable free model/)
    end

    it "includes the OpenRouter provider override in Pi free-policy runtimes" do # @spec MODEL-POLICY-011
      free_model = create(:llm_model, model_id: "moonshotai/kimi-k2:free", provider: "moonshotai", tier: "mid", pricing_tier: "free",
        catalog_source: "openrouter_sync")
      free_runner = create_free_policy_direct_outbound_runner(runner_key: "pi", model_id: free_model.model_id)

      runtime = free_runner.agent_harness_runner_runtime

      expect(runtime.model).to eq("moonshotai/kimi-k2:free")
      expect(runtime.api_provider).to eq("openrouter")
      expect(runtime.env).to include(
        "OPENROUTER_API_KEY" => "sk-openrouter-secret",
        "OPENAI_BASE_URL" => "https://openrouter.ai/api/v1"
      )
    end

    it "includes the OpenRouter provider override in OMP free-policy runtimes" do # @spec MODEL-POLICY-011
      free_model = create(:llm_model, model_id: "qwen/qwen3-coder:free", provider: "qwen", tier: "mid", pricing_tier: "free",
        catalog_source: "openrouter_sync")
      free_runner = create_free_policy_direct_outbound_runner(runner_key: "omp", model_id: free_model.model_id)

      runtime = free_runner.agent_harness_runner_runtime

      expect(runtime.model).to eq("qwen/qwen3-coder:free")
      expect(runtime.api_provider).to eq("openrouter")
      expect(runtime.env).to include(
        "OPENROUTER_API_KEY" => "sk-openrouter-secret",
        "OPENAI_BASE_URL" => "https://openrouter.ai/api/v1"
      )
    end

    it "resolves the highest configured free tier for config-blind dispatch paths" do # @spec MODEL-POLICY-011
      low_model = create(:llm_model, model_id: "openai/gpt-oss-20b:free", provider: "openai", tier: "low", pricing_tier: "free",
        catalog_source: "openrouter_sync")
      high_model = create(:llm_model, model_id: "anthropic/claude-sonnet-4.5:free", provider: "anthropic", tier: "high", pricing_tier: "free",
        catalog_source: "openrouter_sync")
      free_runner = create_free_policy_direct_outbound_runner(runner_key: "kilocode", model_id: low_model.model_id)
      free_runner.update!(tier_model_ids: {
        "low" => low_model.model_id,
        "high" => high_model.model_id
      })

      runtime = free_runner.agent_harness_runner_runtime

      expect(runtime.model).to eq("openai-compatible/anthropic/claude-sonnet-4.5:free")
    end
  end

  describe "#agent_harness_runtime?" do
    it "returns true for copilot providers" do
      runner = build(:runner, runner_key: "copilot")

      expect(runner.agent_harness_runtime?).to be(true)
    end

    it "returns true for opencode direct-outbound providers" do
      user = create(:user)
      api_key = create(:provider_api_key, user: user, api_service_type: "openrouter", api_key: "sk-test")
      runner = build(
        :runner,
        user: user,
        runner_key: "opencode",
        auth_type: "api_key",
        provider_api_key: api_key,
        config: { "opencode" => { "api_provider" => "openrouter", "model" => "test-model" } }
      )

      expect(runner.agent_harness_runtime?).to be(true)
    end

    it "returns true for Pi API-key runners" do
      user = create(:user)
      api_key = create(:provider_api_key, user: user, api_service_type: "minimax", api_key: "sk-test")
      runner = build(
        :runner,
        user: user,
        runner_key: "pi",
        auth_type: "api_key",
        provider_api_key: api_key,
        config: { "pi" => { "api_provider" => "minimax", "model" => "MiniMax-M2.7" } }
      )

      expect(runner.agent_harness_runtime?).to be(true)
      expect(runner.requires_direct_outbound?).to be(true)
    end

    it "returns true for Oh My Pi API-key runners" do
      user = create(:user)
      api_key = create(:provider_api_key, user: user, api_service_type: "deepseek", api_key: "sk-test")
      runner = build(
        :runner,
        user: user,
        runner_key: "omp",
        auth_type: "api_key",
        provider_api_key: api_key,
        config: { "omp" => { "api_provider" => "deepseek", "model" => "deepseek-chat" } }
      )

      expect(runner.agent_harness_runtime?).to be(true)
      expect(runner.requires_direct_outbound?).to be(true)
    end

    it "returns false for claude providers" do
      runner = build(:runner, runner_key: "claude")

      expect(runner.agent_harness_runtime?).to be(false)
    end

    it "returns false for opencode subscription runners" do
      runner = build(:runner, runner_key: "opencode", auth_type: "subscription")

      expect(runner.agent_harness_runtime?).to be(false)
    end
  end

  describe "#direct_outbound_exec_command" do
    it "materializes direct-outbound kilocode config at the upstream path" do
      user = create(:user)
      api_key = create(:provider_api_key, user: user, api_service_type: "anthropic", api_key: "sk-test")
      runner = build(
        :runner,
        user: user,
        runner_key: "kilocode",
        auth_type: "api_key",
        provider_api_key: api_key,
        config: { "kilocode" => { "api_provider" => "anthropic", "model" => "claude-sonnet-4-20250514" } }
      )

      command = runner.direct_outbound_exec_command(command_prefix: %w[kilo run --format json], prompt: "ping")

      expect(command[0, 2]).to eq([ "sh", "-lc" ])
      expect(command[2]).to include("mkdir -p /home/agent/.config/kilocode")
      expect(command[2]).to include("/home/agent/.config/kilocode/kilo.json")
      expect(command[2]).to include("kilo run --format json \"$1\"")
      expect(command[3..]).to eq([ "--", "ping" ])
    end
  end

  describe "#state_key" do
    it "uses the canonical runner key for subscription entries" do
      runner = build(:runner, runner_key: "claude", auth_type: "subscription")

      expect(runner.state_key).to eq("claude")
    end

    it "uses the routing key for api-key entries" do
      user = create(:user)
      api_key = create(:provider_api_key, user: user, api_service_type: "anthropic")
      runner = create(:runner, :api_key, user: user, runner_key: "claude", provider_api_key: api_key)

      expect(runner.state_key).to eq(runner.routing_key)
    end
  end

  describe "#quota_check_runtime" do
    it "returns a subscription runtime for subscription runners with host auth support" do
      runner = build(:runner, runner_key: "claude", auth_type: "subscription")

      runtime = runner.quota_check_runtime

      expect(runtime).to be_a(AgentHarness::ProviderRuntime)
      expect(runtime.unset_env).to include("ANTHROPIC_API_KEY")
    end

    it "returns nil for api-key runners" do
      user = create(:user)
      create(:llm_model, model_id: "moonshotai/kimi-k2-0905", provider: "openrouter", tier: "mid")
      runner = create(
        :runner,
        user: user,
        runner_key: "opencode",
        auth_type: "api_key",
        provider_api_key: create(:provider_api_key, user: user, api_service_type: "openrouter", api_key: "sk-openrouter-secret"),
        config: { "opencode" => { "api_provider" => "openrouter", "model" => "moonshotai/kimi-k2-0905" } }
      )

      runtime = runner.quota_check_runtime

      expect(runtime).to be_nil
    end
  end

  describe "agent-run runner guardrails" do
    let(:user) { create(:user) }

    it "prevents disabling the last runner enabled for agent runs" do
      runner = user.runners.find_by!(runner_key: "claude")

      expect(runner.update(enabled_for_agent_runs: false)).to be(false)
      expect(runner.errors[:enabled_for_agent_runs]).to include("must keep at least one runner enabled for agent runs")
    end

    it "does not allow disabling the default runner even when another runner is enabled" do
      user.runners.create!(runner_key: "cursor")
      default_key = described_class.default_runner_key
      runner = user.runners.find_by!(runner_key: default_key)

      expect(runner.update(enabled_for_agent_runs: false)).to be(false)
      expect(runner.errors[:enabled_for_agent_runs]).to include(
        "#{described_class.display_name(default_key)} must remain enabled for agent runs"
      )
    end

    it "allows disabling a non-default runner when the default remains enabled" do
      runner = user.runners.create!(runner_key: "cursor")

      expect(runner.update(enabled_for_agent_runs: false)).to be(true)
    end
  end

  describe "multiple entries per runner_key" do
    let(:user) { create(:user) }

    it "allows both subscription and api_key entries for the same runner_key" do
      api_key = create(:provider_api_key, user: user, api_service_type: "anthropic")
      api_provider = user.runners.new(
        runner_key: "claude",
        auth_type: "api_key",
        provider_api_key: api_key
      )

      expect(api_provider).to be_valid
      expect(api_provider.save).to be(true)
      expect(user.runners.where(runner_key: "claude").count).to eq(2)
    end

    it "prevents duplicate subscription entries for the same runner_key" do
      duplicate = user.runners.new(runner_key: "claude", auth_type: "subscription")

      expect { duplicate.save!(validate: false) }.to raise_error(ActiveRecord::RecordNotUnique)
    end
  end

  describe "#supports_tier?" do
    it "returns true when the tier has a configured entry" do
      runner = build(:runner, tier_models: { "low" => { "model_id" => "haiku-x", "provider_id" => 17 } })

      expect(runner.supports_tier?("low")).to be(true)
      expect(runner.supports_tier?("high")).to be(false)
    end
  end

  describe "logidze tier_models tracking" do
    include ActiveSupport::Testing::TimeHelpers

    it "captures tier_models updates in snapshots" do
      runner = create(:runner, runner_key: "cursor")
      change_time = 1.minute.from_now

      travel_to(change_time) do
        runner.update!(tier_models: { "low" => { "model_id" => "haiku-x", "provider_id" => 17 } })
      end

      snapshot = runner.reload.at(time: change_time + 1.second)
      expect(snapshot.tier_models).to eq("low" => { "model_id" => "haiku-x", "provider_id" => 17 })
    end
  end

  describe "soft delete lifecycle" do
    it "clears the API key reference when discarding an api-key runner" do
      user = create(:user)
      api_key = create(:provider_api_key, user: user, api_service_type: "anthropic")
      runner = create(:runner, :api_key, user: user, runner_key: "cursor", provider_api_key: api_key)

      expect(runner.discard).to be(true)

      discarded_runner = described_class.with_discarded.find(runner.id)
      expect(discarded_runner).to be_discarded
      expect(discarded_runner.provider_api_key_id).to be_nil
    end

    it "does not clear the API key reference when discard is aborted by a guard" do
      user = create(:user)
      api_key = create(:provider_api_key, user: user, api_service_type: "anthropic")
      runner = create(:runner, :api_key, user: user, runner_key: "cursor", provider_api_key: api_key)
      user.runners.kept_only.where.not(id: runner.id).update_all(enabled_for_agent_runs: false, enabled_for_fallback: false)

      expect(runner.discard).to be(false)

      expect(runner.provider_api_key_id).to eq(api_key.id)
      expect(runner.errors[:base]).to include("Cannot delete the last runner enabled for agent runs")

      persisted_runner = described_class.find(runner.id)
      expect(persisted_runner).to be_kept
      expect(persisted_runner.provider_api_key_id).to eq(api_key.id)
    end
  end

  describe "free-model rotation snapshot clearing" do
    let(:user) { create(:user) }
    let(:api_key) { create(:provider_api_key, user: user, api_service_type: "openrouter") }
    let(:free_model) { create(:llm_model, :free, model_id: "free-orig", tier: "high", capability_score: 5.0) }
    let(:runner) do
      create(:runner, user: user, runner_key: "opencode", auth_type: "api_key",
        provider_api_key: api_key, config: { "opencode" => { "model_policy" => "free" } },
        tier_model_ids: LlmModel::TIERS.index_with { free_model.model_id })
    end

    it "clears the recovery snapshot when the user changes tier_model_ids" do
      runner_state = user.runner_states.create!(runner_name: runner.state_key)
      runner_state.record_preferred_tier_model_ids!("high" => free_model.model_id)

      other_free = create(:llm_model, :free, model_id: "free-other", tier: "high", capability_score: 6.0)
      runner.update!(tier_model_ids: LlmModel::TIERS.index_with { other_free.model_id })

      expect(runner_state.reload.preferred_tier_model_ids).to be_nil
    end

    it "does not clear the snapshot during a system rotation" do
      runner_state = user.runner_states.create!(runner_name: runner.state_key)
      runner_state.record_preferred_tier_model_ids!("high" => free_model.model_id)

      other_free = create(:llm_model, :free, model_id: "free-other", tier: "high", capability_score: 6.0)
      runner.rotating_tier_models = true
      runner.update!(tier_model_ids: LlmModel::TIERS.index_with { other_free.model_id })

      expect(runner_state.reload.preferred_tier_model_ids).to eq("high" => free_model.model_id)
    end
  end

  def claude_native_secret(access_token)
    {
      "claudeAiOauth" => {
        "accessToken" => access_token,
        "refreshToken" => "refresh-token"
      }
    }.to_json
  end
end
