# frozen_string_literal: true

require "rails_helper"

RSpec.describe Models::DetectContractDrift do
  before { LlmModel.delete_all }

  describe ".call" do
    context "with a clean catalog" do
      before do
        create(:llm_model, :openai, model_id: "gpt-4o", tier: "mid", active: true)
        create(:llm_model, model_id: "claude-sonnet-4-6", provider: "anthropic", tier: "mid", active: true)
      end

      it "returns no findings" do
        result = described_class.call
        expect(result.drift?).to be(false)
        expect(result.findings).to be_empty
      end
    end

    context "with an auth-mode-gated active model" do
      # gpt-5.5-pro is api_key-only per the agent-harness compatibility
      # contract, so a subscription codex run picks it up as a
      # :auth_mode_gated_for_model drift. Confirms the detector groups the
      # finding by (provider, runner_key, auth_type) — the api_key auth
      # mode would NOT flag the same model.
      let(:auth_gated_id) { "auth-gated-#{SecureRandom.hex(4)}" }

      before do
        create(:llm_model, :openai, model_id: auth_gated_id, tier: "high", active: true)
        allow(AgentHarness).to receive(:model_compatibility) do |args|
          if args[:model_id] == auth_gated_id && args[:auth_mode] == :subscription
            AgentHarness::ModelCompatibility::Result.new(
              runner: args[:runner],
              model_id: args[:model_id],
              auth_mode: args[:auth_mode],
              supported: false,
              reason: AgentHarness::ModelCompatibility::UNSUPPORTED_AUTH_MODE_FOR_MODEL_REASON,
              fallback_model_id: "gpt-5-codex"
            )
          else
            AgentHarness::ModelCompatibility::Result.new(
              runner: args[:runner],
              model_id: args[:model_id],
              auth_mode: args[:auth_mode],
              supported: nil
            )
          end
        end
      end

      it "groups the model under one finding per runner/auth combo" do
        result = described_class.call
        expect(result.drift?).to be(true)

        codex_subscription_findings = result.findings.select do |f|
          f[:runner_key] == "codex" && f[:auth_type] == "subscription"
        end
        expect(codex_subscription_findings).not_to be_empty
        codex_subscription_findings.each do |finding|
          expect(finding[:models]).to include(auth_gated_id)
        end
      end
    end

    context "with an active gpt-5.3-codex catalog row" do
      before do
        create(:llm_model, :openai, model_id: "gpt-5.3-codex", tier: "high", active: true)
        allow(AgentHarness).to receive(:model_compatibility) do |args|
          if args[:runner].to_s == "codex" &&
              args[:model_id] == "gpt-5.3-codex" &&
              args[:auth_mode] == :subscription
            unsupported_result(args)
          else
            unknown_result(args)
          end
        end
      end

      it "reports the codex subscription incompatibility instead of suppressing it" do
        result = described_class.call

        expect(result.drift?).to be(true)
        expect(result.findings).to include(
          hash_including(
            provider: "openai",
            runner_key: "codex",
            auth_type: "subscription",
            models: include("gpt-5.3-codex"),
            incompatibility_types: include(:auth_mode_gated_for_model)
          )
        )
      end
    end

    context "with an inactive catalog row" do
      let(:inactive_id) { "inactive-#{SecureRandom.hex(4)}" }

      before do
        create(:llm_model, :openai, model_id: inactive_id, tier: "high", active: false)
      end

      it "does not flag inactive models" do
        result = described_class.call
        expect(result.drift?).to be(false)
      end
    end

    it "respects a custom runner_keys filter" do
      gated_id = "filter-#{SecureRandom.hex(4)}"
      create(:llm_model, :openai, model_id: gated_id, tier: "high", active: true)
      allow(AgentHarness).to receive(:model_compatibility) do |args|
        next unsupported_result(args) if args[:model_id] == gated_id && args[:auth_mode] == :subscription

        unknown_result(args)
      end

      result = described_class.call(runner_keys: %w[claude])
      # The auth-mode-gated model is openai, only relevant for codex; with
      # the filter set to only claude, no findings should be reported.
      expect(result.findings).to be_empty
    end

    it "checks direct-outbound runners included in the shared key list" do
      model_id = "pareto-#{SecureRandom.hex(4)}"
      create(:llm_model, :openai, model_id: model_id, tier: "mid", active: true)

      allow(Runners::ModelCompatibility).to receive(:call).and_return(
        AgentHarness::ModelCompatibility::Result.new(
          runner: :opencode,
          model_id: model_id,
          auth_mode: :subscription,
          supported: nil
        )
      )

      described_class.call(runner_keys: %w[openrouter_pareto], auth_types: %w[subscription])

      expect(Runners::ModelCompatibility).to have_received(:call).with(hash_including(
        runner_key: "openrouter_pareto",
        model_id: model_id,
        auth_type: "subscription"
      ))
    end

    it "caps findings per (provider, runner, auth_type) group" do
      stub_const("Models::DetectContractDrift::MAX_FINDINGS_PER_GROUP", 2)
      model_ids = 5.times.map { |i| "cap-#{SecureRandom.hex(4)}-#{i}" }
      model_ids.each do |id|
        create(:llm_model, :openai, model_id: id, tier: "low", active: true)
      end
      allow(AgentHarness).to receive(:model_compatibility) do |args|
        AgentHarness::ModelCompatibility::Result.new(
          runner: args[:runner],
          model_id: args[:model_id],
          auth_mode: args[:auth_mode],
          supported: false,
          reason: AgentHarness::ModelCompatibility::UNSUPPORTED_CLI_VERSION_REASON
        )
      end

      result = described_class.call
      codex_findings = result.findings.select { |f| f[:runner_key] == "codex" }
      expect(codex_findings).not_to be_empty
      codex_findings.each do |finding|
        expect(finding[:models].size).to be <= 2
      end
    end

    it "produces a stable fingerprint across identical findings" do
      id = "fingerprint-#{SecureRandom.hex(4)}"
      create(:llm_model, :openai, model_id: id, tier: "high", active: true)
      allow(AgentHarness).to receive(:model_compatibility) do |args|
        next unsupported_result(args, AgentHarness::ModelCompatibility::UNSUPPORTED_AUTH_MODE_FOR_MODEL_REASON) if args[:auth_mode] == :subscription

        unknown_result(args)
      end

      first = described_class.call
      second = described_class.call
      expect(first.fingerprint).to eq(second.fingerprint)
    end

    it "changes the fingerprint when incompatibility guidance changes" do
      id = "fingerprint-guidance-#{SecureRandom.hex(4)}"
      create(:llm_model, :openai, model_id: id, tier: "high", active: true)

      allow(AgentHarness).to receive(:model_compatibility) do |args|
        next unknown_result(args) unless args[:auth_mode] == :subscription

        unsupported_result(args, AgentHarness::ModelCompatibility::UNSUPPORTED_CLI_VERSION_REASON)
      end
      cli_gated = described_class.call

      allow(AgentHarness).to receive(:model_compatibility) do |args|
        next unknown_result(args) unless args[:auth_mode] == :subscription

        AgentHarness::ModelCompatibility::Result.new(
          runner: args[:runner],
          model_id: args[:model_id],
          auth_mode: args[:auth_mode],
          supported: false,
          reason: AgentHarness::ModelCompatibility::UNSUPPORTED_AUTH_MODE_FOR_MODEL_REASON,
          fallback_model_id: "gpt-5.4"
        )
      end
      auth_gated = described_class.call

      expect(cli_gated.fingerprint).not_to eq(auth_gated.fingerprint)
    end

    it "changes the fingerprint when the replacement model changes" do
      id = "fingerprint-replacement-#{SecureRandom.hex(4)}"
      create(:llm_model, :openai, model_id: id, tier: "high", active: true)
      first = contract_drift_fingerprint_for(id, fallback_model_id: "gpt-5-codex")
      second = contract_drift_fingerprint_for(id, fallback_model_id: "gpt-5.4")

      expect(first).not_to eq(second)
    end
  end

  # Helpers to keep individual examples under the RSpec line budget.
  def unsupported_result(args, reason = AgentHarness::ModelCompatibility::UNSUPPORTED_AUTH_MODE_FOR_MODEL_REASON)
    AgentHarness::ModelCompatibility::Result.new(
      runner: args[:runner],
      model_id: args[:model_id],
      auth_mode: args[:auth_mode],
      supported: false,
      reason: reason,
      fallback_model_id: "gpt-5-codex"
    )
  end

  def unknown_result(args)
    AgentHarness::ModelCompatibility::Result.new(
      runner: args[:runner],
      model_id: args[:model_id],
      auth_mode: args[:auth_mode],
      supported: nil
    )
  end

  def contract_drift_fingerprint_for(model_id, fallback_model_id:)
    allow(AgentHarness).to receive(:model_compatibility) do |args|
      next unknown_result(args) unless args[:model_id] == model_id && args[:auth_mode] == :subscription

      AgentHarness::ModelCompatibility::Result.new(
        runner: args[:runner],
        model_id: args[:model_id],
        auth_mode: args[:auth_mode],
        supported: false,
        reason: AgentHarness::ModelCompatibility::UNSUPPORTED_AUTH_MODE_FOR_MODEL_REASON,
        fallback_model_id: fallback_model_id
      )
    end

    described_class.call.fingerprint
  end
end
