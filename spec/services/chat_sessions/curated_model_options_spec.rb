# frozen_string_literal: true

require "rails_helper"

RSpec.describe ChatSessions::CuratedModelOptions do
  let(:user) { create(:user, :owner) }
  let(:provider_api_key) { create(:provider_api_key, user:, api_service_type: "openai") }
  let(:runner) { create(:runner, :api_key, user:, provider_api_key:, runner_key: "codex") }

  # @spec ONBOARD-CHAT-014
  it "reports a low-tier rejection without treating a higher-tier catalog as usable" do
    create(:llm_model, :openai, tier: "mid", supports_tools: true)

    resolution = described_class.resolve_with_diagnostics(runner:)

    expect(resolution.option).to be_nil
    expect(resolution.rejection_reasons).to eq([ :low_tier_unavailable ])
  end

  # @spec ONBOARD-CHAT-014
  it "does not let stale unavailable evidence suppress a Low-tier onboarding model" do
    model = create(:llm_model, :openai, tier: "low", supports_tools: true)
    create(
      :model_availability_check,
      llm_model: model,
      runner_key: "codex",
      auth_type: "api_key",
      status: "unavailable",
      checked_at: 7.hours.ago,
      expires_at: 1.hour.ago
    )

    resolution = described_class.resolve_with_diagnostics(runner:)

    expect(resolution.option).to have_attributes(model_id: model.model_id, tier: "low")
  end

  # @spec ONBOARD-CHAT-015 MODEL-AVAILABILITY-009
  it "does not let global unavailable evidence suppress a new API-key runner" do
    model = create(:llm_model, :openai, tier: "low", supports_tools: true)
    create(
      :model_availability_check,
      llm_model: model,
      runner_key: "codex",
      auth_type: "api_key",
      status: "unavailable",
      account: nil,
      checked_at: Time.current,
      expires_at: ModelAvailabilityCheck::DEFAULT_TTL.from_now
    )

    resolution = described_class.resolve_with_diagnostics(runner:)

    expect(resolution.option).to have_attributes(model_id: model.model_id, tier: "low")
  end

  # @spec ONBOARD-CHAT-015 MODEL-AVAILABILITY-009
  it "does not consume unavailable evidence from the subscription auth context" do
    model = create(:llm_model, :openai, tier: "low", supports_tools: true)
    create(
      :model_availability_check,
      llm_model: model,
      runner_key: "codex",
      auth_type: "subscription",
      status: "unavailable",
      account: nil,
      checked_at: Time.current,
      expires_at: ModelAvailabilityCheck::DEFAULT_TTL.from_now
    )

    resolution = described_class.resolve_with_diagnostics(runner:)

    expect(resolution.option).to have_attributes(model_id: model.model_id, tier: "low")
  end

  # @spec ONBOARD-CHAT-015 MODEL-AVAILABILITY-009
  it "uses fresh unavailable evidence scoped to the API-key runner account" do
    model = create(:llm_model, :openai, tier: "low", supports_tools: true)
    create(
      :model_availability_check,
      llm_model: model,
      runner_key: "codex",
      auth_type: "api_key",
      status: "unavailable",
      account: user.account,
      checked_at: Time.current,
      expires_at: ModelAvailabilityCheck::DEFAULT_TTL.from_now
    )

    resolution = described_class.resolve_with_diagnostics(runner:)

    expect(resolution.option).to be_nil
    expect(resolution.rejection_reasons).to eq([ :unavailable ])
  end

  # @spec ONBOARD-CHAT-014
  it "reports runner incompatibility separately from missing chat-tool support" do
    incompatible_runner = create(:runner, user:, runner_key: "codex", auth_type: "subscription")
    create(:llm_model, :openai, model_id: "gpt-5.5-pro", tier: "low", supports_tools: true)

    resolution = described_class.resolve_with_diagnostics(runner: incompatible_runner)
    error = ChatSessions::ModelUnavailableError.new(
      runner: incompatible_runner,
      rejection_reasons: resolution.rejection_reasons
    )

    expect(resolution.rejection_reasons).to eq([ :runner_incompatible ])
    expect(error.message).to include("not compatible with this runner")
    expect(error.message).not_to include("do not support chat tools")
  end
end
