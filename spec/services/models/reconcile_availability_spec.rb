# frozen_string_literal: true

require "rails_helper"

RSpec.describe Models::ReconcileAvailability do
  let(:compat_result_class) { Runners::ModelCompatibility::Result }

  def stub_compat(model_id, supported:, incompatibility_type: nil, reason: nil, replacement_model_id: nil)
    allow(Runners::ModelCompatibility).to receive(:call)
      .with(hash_including(model_id: model_id))
      .and_return(
        compat_result_class.new(
          supported: supported,
          reason: reason,
          incompatibility_type: incompatibility_type,
          replacement_model_id: replacement_model_id,
          source: "agent_harness"
        )
      )
  end

  describe "#refresh!" do
    # @spec MODEL-AVAILABILITY-004
    it "records an available check for a compatible model" do
      model = create(:llm_model, :openai, model_id: "gpt-test-available")
      stub_compat(model.model_id, supported: true)

      described_class.new.refresh!(runner_key: "codex", auth_type: "subscription")

      check = ModelAvailabilityCheck.find_by!(llm_model: model, runner_key: "codex", auth_type: "subscription")
      expect(check).to have_attributes(status: "available", source: "agent_harness_compat", account_id: nil)
    end

    it "records an unavailable check with a policy-eligible replacement" do
      model = create(:llm_model, :openai, model_id: "gpt-test-rejected", tier: "mid", capability_score: 9.0)
      alternative = create(:llm_model, :openai, model_id: "gpt-test-alt", tier: "mid", capability_score: 8.0)
      stub_compat(model.model_id, supported: false, incompatibility_type: :auth_mode_gated_for_model, reason: "nope")
      stub_compat(alternative.model_id, supported: true)

      described_class.new.refresh!(runner_key: "codex", auth_type: "subscription")

      check = ModelAvailabilityCheck.find_by!(llm_model: model, runner_key: "codex", auth_type: "subscription")
      expect(check.status).to eq("unavailable")
      expect(check.incompatibility_type).to eq("auth_mode_gated_for_model")
    end

    it "does not record a check when compatibility is unknown" do
      model = create(:llm_model, :openai, model_id: "gpt-test-unknown")
      stub_compat(model.model_id, supported: nil)

      described_class.new.refresh!(runner_key: "codex", auth_type: "subscription")

      expect(ModelAvailabilityCheck.where(llm_model: model)).to be_empty
    end

    # @spec MODEL-AVAILABILITY-004
    it "does not recheck a model whose evidence is still fresh (bounded, deduplicated)" do
      model = create(:llm_model, :openai, model_id: "gpt-test-fresh")
      stub_compat(model.model_id, supported: true)
      described_class.new.refresh!(runner_key: "codex", auth_type: "subscription")

      described_class.new.refresh!(runner_key: "codex", auth_type: "subscription")

      expect(Runners::ModelCompatibility).to have_received(:call).with(hash_including(model_id: model.model_id)).once
    end

    it "rechecks a model whose evidence has gone stale" do
      model = create(:llm_model, :openai, model_id: "gpt-test-stale")
      stub_compat(model.model_id, supported: true)
      described_class.new.refresh!(runner_key: "codex", auth_type: "subscription")
      ModelAvailabilityCheck.find_by!(llm_model: model).update!(checked_at: (ModelAvailabilityCheck::DEFAULT_TTL + 1.hour).ago, expires_at: 1.hour.ago)

      stub_compat(model.model_id, supported: false, incompatibility_type: :model_not_found, reason: "gone")
      described_class.new.refresh!(runner_key: "codex", auth_type: "subscription")

      expect(ModelAvailabilityCheck.find_by!(llm_model: model).status).to eq("unavailable")
    end

    it "ignores runner keys without a mapped provider" do
      expect(described_class.new.refresh!(runner_key: "opencode", auth_type: "api_key")).to eq([])
    end
  end

  describe "#record_rejection!" do
    # @spec MODEL-AVAILABILITY-005
    it "upserts an unavailable check without touching the LlmModel's active flag" do
      model = create(:llm_model, :openai, tier: "mid", active: true)

      described_class.new.record_rejection!(
        llm_model: model, runner_key: "codex", auth_type: "subscription",
        reason: "not supported when using Codex with a ChatGPT account", incompatibility_type: :subscription_only
      )

      expect(model.reload.active).to be(true)
      check = ModelAvailabilityCheck.find_by!(llm_model: model, runner_key: "codex", auth_type: "subscription")
      expect(check).to have_attributes(status: "unavailable", source: "runtime_rejection", retry_count: 1)
    end

    # @spec MODEL-AVAILABILITY-005
    it "bounds retry_count by MAX_RETRIES across repeated rejections" do
      model = create(:llm_model, :openai, tier: "mid")

      (described_class::MAX_RETRIES + 2).times do
        described_class.new.record_rejection!(
          llm_model: model, runner_key: "codex", auth_type: "subscription", reason: "still rejected"
        )
      end

      check = ModelAvailabilityCheck.find_by!(llm_model: model, runner_key: "codex", auth_type: "subscription")
      expect(check.retry_count).to eq(described_class::MAX_RETRIES)
    end

    # @spec MODEL-AVAILABILITY-006
    it "surfaces a policy-eligible replacement candidate, never a hardcoded model id" do
      model = create(:llm_model, :openai, model_id: "gpt-5.6", tier: "mid", capability_score: 9.0)
      create(:llm_model, :openai, model_id: "gpt-5.2-codex", tier: "high", capability_score: 5.0)
      better_fit = create(:llm_model, :openai, model_id: "gpt-5.6-terra", tier: "mid", capability_score: 9.0)

      check = described_class.new.record_rejection!(
        llm_model: model, runner_key: "codex", auth_type: "subscription", reason: "not supported"
      )

      expect(check.replacement_model_id).to eq(better_fit.model_id)
      expect(check.replacement_model_id).not_to eq("gpt-5.2-codex")
    end

    it "reports no replacement when no eligible candidate remains" do
      model = create(:llm_model, :openai, tier: "mid")

      check = described_class.new.record_rejection!(
        llm_model: model, runner_key: "codex", auth_type: "subscription", reason: "not supported"
      )

      expect(check.replacement_model_id).to be_nil
    end

    # @spec MODEL-AVAILABILITY-001
    it "isolates rejections by account so one account's rejection is not read as another's" do
      model = create(:llm_model, :openai, tier: "mid")
      account_a = create(:account)
      account_b = create(:account)

      described_class.new.record_rejection!(
        llm_model: model, runner_key: "codex", auth_type: "subscription",
        account: account_a, reason: "rejected for account A"
      )

      expect(ModelAvailabilityCheck.find_by(llm_model: model, runner_key: "codex", auth_type: "subscription", account: account_b)).to be_nil
      expect(ModelAvailabilityCheck.find_by!(llm_model: model, runner_key: "codex", auth_type: "subscription", account: account_a).reason)
        .to eq("rejected for account A")
    end
  end
end
