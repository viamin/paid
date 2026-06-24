# frozen_string_literal: true

require "rails_helper"

RSpec.describe Runners::ModelCompatibility do
  describe ".call" do
    subject(:result) do
      described_class.call(runner_key: runner_key, model_id: model_id, auth_type: auth_type)
    end

    context "when agent-harness exposes the compatibility API" do
      let(:runner_key) { "codex" }
      let(:model_id) { "gpt-5.5" }
      let(:auth_type) { "subscription" }

      let(:harness_result) do
        AgentHarness::ModelCompatibility::Result.new(
          runner: :codex,
          model_id: "gpt-5.5",
          auth_mode: :subscription,
          supported: false,
          reason: AgentHarness::ModelCompatibility::UNSUPPORTED_CLI_VERSION_REASON,
          minimum_cli_version: "0.116.0",
          cli_version_requirement: ">= 0.116.0",
          fallback_model_id: "gpt-5-codex",
          source: :static_contract
        )
      end

      before do
        allow(AgentHarness).to receive(:model_compatibility).and_return(harness_result)
      end

      it "delegates to agent-harness and returns its result" do
        expect(result).to have_attributes(
          supported: false,
          reason: "'gpt-5.5' requires Codex CLI >= 0.116.0",
          incompatibility_type: :cli_version_gated,
          source: "agent_harness"
        )
        expect(result).to be_unsupported
      end
    end

    context "with Codex runner" do
      let(:runner_key) { "codex" }
      let(:auth_type) { "subscription" }

      context "with CLI-version-gated model (gpt-5.5)" do
        let(:model_id) { "gpt-5.5" }

        it "returns supported with the current Codex CLI contract" do
          expect(result).to have_attributes(
            supported: true,
            incompatibility_type: nil,
            source: "agent_harness"
          )
          expect(result.reason).to be_nil
          expect(result).to be_supported
        end
      end

      context "with CLI-version-gated model (gpt-5.5-pro)" do
        let(:model_id) { "gpt-5.5-pro" }

        it "returns unknown because agent-harness does not advertise it yet" do
          expect(result).to have_attributes(
            supported: nil,
            incompatibility_type: nil,
            source: "agent_harness"
          )
          expect(result).to be_unknown
        end
      end

      context "with subscription auth and non-OpenAI model" do
        let(:model_id) { "claude-opus-4-5" }

        before do
          create(:llm_model, model_id: "claude-opus-4-5", provider: "anthropic")
        end

        it "returns unsupported with provider_mismatch type" do
          expect(result).to have_attributes(
            supported: false,
            incompatibility_type: :provider_mismatch,
            source: "paid_catalog"
          )
          expect(result.reason).to include("anthropic")
          expect(result.reason).to include("openai")
        end
      end

      context "with subscription auth and a compatible OpenAI model" do
        let(:model_id) { "gpt-5.2-codex" }
        let(:auth_type) { "subscription" }

        before do
          create(:llm_model, :openai, model_id: "gpt-5.2-codex")
        end

        it "returns unknown (not unsupported) — subscription entitlements vary" do
          expect(result).to be_unknown
          expect(result.source).to eq("agent_harness")
        end
      end

      context "with api_key auth and a model not in the CLI-gated list" do
        let(:model_id) { "gpt-5.4" }
        let(:auth_type) { "api_key" }

        before do
          create(:llm_model, :openai, model_id: "gpt-5.4")
        end

        it "returns unknown — api_key entitlements depend on the account" do
          expect(result).to be_unknown
        end
      end

      context "with api_key auth and a CLI-version-gated model" do
        let(:model_id) { "gpt-5.5" }
        let(:auth_type) { "api_key" }

        it "returns supported with the updated Codex CLI pin" do
          expect(result).to be_supported
          expect(result.incompatibility_type).to be_nil
        end
      end
    end

    context "with standard runner (claude)" do
      let(:runner_key) { "claude" }
      let(:auth_type) { "subscription" }

      context "with a model from the correct provider (anthropic)" do
        let(:model_id) { "claude-opus-4-5" }

        before do
          create(:llm_model, model_id: "claude-opus-4-5", provider: "anthropic")
        end

        it "returns unknown — subscription entitlements are not statically checkable" do
          expect(result).to be_unknown
          expect(result.source).to eq("agent_harness")
        end
      end

      context "with a model from the wrong provider" do
        let(:model_id) { "gpt-5.4" }

        before do
          create(:llm_model, :openai, model_id: "gpt-5.4")
        end

        it "returns unsupported with provider_mismatch" do
          expect(result).to have_attributes(
            supported: false,
            incompatibility_type: :provider_mismatch,
            source: "paid_catalog"
          )
          expect(result.reason).to include("openai")
          expect(result.reason).to include("anthropic")
        end
      end

      context "with an unknown model_id" do
        let(:model_id) { "claude-unknown-model" }

        it "returns unknown" do
          expect(result).to be_unknown
          expect(result.source).to eq("agent_harness")
        end
      end
    end

    context "with gemini runner" do
      let(:runner_key) { "gemini" }
      let(:auth_type) { "subscription" }

      context "with a Google model" do
        let(:model_id) { "gemini-2.0-flash" }

        before do
          create(:llm_model, model_id: "gemini-2.0-flash", provider: "google")
        end

        it "returns unknown" do
          expect(result).to be_unknown
        end
      end

      context "with a non-Google model" do
        let(:model_id) { "gpt-5.4" }

        before do
          create(:llm_model, :openai, model_id: "gpt-5.4")
        end

        it "returns unsupported with provider_mismatch" do
          expect(result).to be_unsupported
          expect(result.incompatibility_type).to eq(:provider_mismatch)
        end
      end
    end

    context "with a direct-outbound runner (opencode)" do
      let(:runner_key) { "opencode" }
      let(:model_id) { "gpt-5.4" }
      let(:auth_type) { "api_key" }

      it "returns unknown — direct-outbound compatibility is determined by runner config" do
        expect(result).to be_unknown
        expect(result.source).to eq("agent_harness")
      end
    end

    context "with an unknown runner" do
      let(:runner_key) { "unknown_runner" }
      let(:model_id) { "some-model" }
      let(:auth_type) { "api_key" }

      it "returns unknown" do
        expect(result).to be_unknown
      end
    end
  end

  describe "Result" do
    it "supported? returns true when supported is true" do
      r = described_class::Result.new(supported: true, source: "test")
      expect(r).to be_supported
      expect(r).not_to be_unsupported
      expect(r).not_to be_unknown
    end

    it "unsupported? returns true when supported is false" do
      r = described_class::Result.new(supported: false, source: "test")
      expect(r).to be_unsupported
      expect(r).not_to be_supported
      expect(r).not_to be_unknown
    end

    it "unknown? returns true when supported is nil" do
      r = described_class::Result.new(supported: nil, source: "test")
      expect(r).to be_unknown
      expect(r).not_to be_supported
      expect(r).not_to be_unsupported
    end
  end
end
