# frozen_string_literal: true

require "rails_helper"

RSpec.describe Runners::ResolveTierModel do
  describe ".call" do
    let(:user) { create(:user) }
    let(:runner_key) { "codex" }
    let(:runner) do
      api_key = create(:runner_api_key, user: user, api_service_type: "openai")
      create(:runner, :api_key, user: user, runner_key: runner_key, provider_api_key: api_key, tier_models: {})
    end

    it "prefers the runner tier mapping" do
      runner.update!(tier_models: {
        "mid" => { "model_id" => "runner-mid", "provider_id" => 17 }
      })

      result = described_class.call(runner: runner, tier: "mid", user: user)

      expect(result).to have_attributes(
        model_id: "runner-mid",
        provider_id: 17,
        source: "runner"
      )
      expect(result).to be_success
    end

    it "falls back to the matching provider tier mapping" do
      provider_runner = Runner.new(runner_key: runner_key)
      create(
        :provider,
        user: user,
        provider_key: runner_key,
        auth_type: "subscription",
        tier_models: {
          "mid" => { "model_id" => "provider-mid", "provider_id" => 23 }
        }
      )

      result = described_class.call(runner: provider_runner, tier: "mid", user: user)

      expect(result).to have_attributes(
        model_id: "provider-mid",
        provider_id: 23,
        source: "provider"
      )
      expect(result).to be_success
    end

    it "falls back to the default tier model" do
      create(:llm_model, model_id: "default-mid", provider: "openai", tier: "mid", capability_score: 9.0)

      result = described_class.call(runner: runner, tier: "mid", user: user)

      expect(result).to have_attributes(
        model_id: "default-mid",
        provider_id: user.provider_for(runner)&.id,
        source: "default"
      )
      expect(result).to be_success
    end

    it "fails when no runner, provider, or default model is configured for the tier" do
      result = described_class.call(runner: runner, tier: "high", user: user)

      expect(result).to be_failure
      expect(result.error).to eq("no model configured for #{runner_key} at high")
    end

    context "when tier_models is empty but tier_model_ids is configured" do
      it "honors the runner tier_model_ids mapping instead of drifting to the default" do
        create(:llm_model, :openai, model_id: "gpt-5-codex", tier: "high", capability_score: 8.0)
        # A higher-capability default candidate that must NOT win over the
        # admin-configured value.
        create(:llm_model, :openai, model_id: "gpt-5.5-pro", tier: "high", capability_score: 9.9)
        runner.update!(tier_model_ids: { "high" => "gpt-5-codex" })

        result = described_class.call(runner: runner, tier: "high", user: user)

        expect(result).to be_success
        expect(result.model_id).to eq("gpt-5-codex")
        expect(result.source).to eq("runner")
      end

      it "honors the provider tier_model_ids mapping when the runner has none" do
        create(:llm_model, :openai, model_id: "gpt-5-codex", tier: "high", capability_score: 8.0)
        provider_runner = Runner.new(runner_key: runner_key)
        provider = create(
          :provider,
          user: user,
          provider_key: runner_key,
          auth_type: "subscription",
          tier_model_ids: { "high" => "gpt-5-codex" }
        )

        result = described_class.call(runner: provider_runner, tier: "high", user: user)

        expect(result).to be_success
        expect(result.model_id).to eq("gpt-5-codex")
        expect(result.source).to eq("provider")
        expect(result.provider_id).to eq(provider.id)
      end
    end

    context "when falling back to the default under subscription auth" do
      it "filters auth-mode-incompatible default models using the runner's actual auth_type" do
        subscription_runner = create(:provider, user: user, provider_key: "codex",
                                                auth_type: "subscription", tier_models: {},
                                                tier_model_ids: {})
        # gpt-5.5-pro is api_key-only; it must be filtered under subscription
        # so the run does not dispatch an incompatible model (#2968).
        create(:llm_model, :openai, model_id: "gpt-5.5-pro", tier: "high", capability_score: 9.9)
        create(:llm_model, :openai, model_id: "gpt-5.2-codex", tier: "high", capability_score: 9.0)

        result = described_class.call(runner: subscription_runner, tier: "high", user: user)

        expect(result).to be_success
        expect(result.model_id).to eq("gpt-5.2-codex")
        expect(result.source).to eq("default")
      end

      it "uses the matched provider auth_type for bare runner candidates" do
        create(:provider, user: user, provider_key: "codex", auth_type: "subscription", tier_models: {}, tier_model_ids: {})
        create(:llm_model, :openai, model_id: "gpt-5.5-pro", tier: "high", capability_score: 9.9)
        create(:llm_model, :openai, model_id: "gpt-5.2-codex", tier: "high", capability_score: 9.0)

        result = described_class.call(runner: Runner.new(runner_key: "codex"), tier: "high", user: user)

        expect(result).to be_success
        expect(result.model_id).to eq("gpt-5.2-codex")
        expect(result.source).to eq("default")
      end
    end

    context "when the runner tier mapping specifies a gpt-5.5 model" do
      before do
        runner.update_columns(tier_models: {
          "mid" => { "model_id" => "gpt-5.5", "provider_id" => 99 }
        })
      end

      it "returns success with the runner mapping" do
        result = described_class.call(runner: runner, tier: "mid", user: user)

        expect(result).to be_success
        expect(result.model_id).to eq("gpt-5.5")
      end

      it "checks compatibility once per candidate" do
        expect(Runners::ModelCompatibility).to receive(:call).once.and_call_original

        described_class.call(runner: runner, tier: "mid", user: user)
      end
    end

    context "when the runner tier mapping specifies a compatible model" do
      before do
        runner.update_columns(tier_models: {
          "mid" => { "model_id" => "gpt-5.4", "provider_id" => 99 }
        })
        create(:llm_model, :openai, model_id: "gpt-5.4")
      end

      it "returns success" do
        result = described_class.call(runner: runner, tier: "mid", user: user)

        expect(result).to be_success
        expect(result.model_id).to eq("gpt-5.4")
      end

      it "checks compatibility once per candidate" do
        expect(Runners::ModelCompatibility).to receive(:call).once.and_call_original

        described_class.call(runner: runner, tier: "mid", user: user)
      end
    end
  end
end
