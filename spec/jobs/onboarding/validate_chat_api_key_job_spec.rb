# frozen_string_literal: true

require "rails_helper"

RSpec.describe Onboarding::ValidateChatApiKeyJob do
  let(:account) { create(:account) }
  let(:user) { create(:user, :owner, account: account) }
  let(:free_model) { create(:llm_model, :free) }

  before do
    Onboarding::StartOnboarding.call(account: account)
    Onboarding::CompleteStep.call(account: account, step: "account_profile")
    allow(AgentHarness).to receive(:check_provider).and_return(
      { status: "error", error_category: :authentication }
    )
    RunnerSupport::API_SERVICE_TYPES.keys.excluding("openrouter").each do |service_type|
      create(:llm_model,
        provider: service_type,
        model_id: "#{service_type}-chat-low",
        tier: "low",
        supports_tools: true)
    end
  end

  # @spec ONBOARD-CHAT-003
  it "removes an asynchronously rejected bootstrap and restores the API-key retry step" do
    result = Onboarding::ConfigureChatRunner.call(
      account: account,
      user: user,
      api_service_type: "openrouter",
      api_key: "invalid-key"
    )
    result.runner.update!(tier_model_ids: { "high" => free_model.model_id })

    allow(ActionCable.server).to receive(:broadcast).and_call_original

    described_class.perform_now(result.runner.id)

    expect_retry_broadcast_for(result.chat_session)

    expect { result.provider_api_key.reload }.to raise_error(ActiveRecord::RecordNotFound)
    expect { result.runner.reload }.to raise_error(ActiveRecord::RecordNotFound)
    expect { result.chat_session.reload }.to raise_error(ActiveRecord::RecordNotFound)
    expect(account.onboarding_steps.find_by(step: "chat_api_key")).to have_attributes(
      status: "in_progress",
      completed_at: nil,
      metadata: {}
    )
    expect(account.onboarding_steps.find_by(step: "github_token")).to be_pending
  end

  # @spec ONBOARD-CHAT-003
  it "checks a fixed Anthropic runner with its submitted API key" do
    result = Onboarding::ConfigureChatRunner.call(
      account: account,
      user: user,
      api_service_type: "anthropic",
      api_key: "invalid-anthropic-key"
    )

    described_class.perform_now(result.runner.id)

    expect(AgentHarness).to have_received(:check_provider).with(
      :claude,
      timeout: Onboarding::ConfigureChatRunner::HEALTH_CHECK_TIMEOUT,
      provider_runtime: have_attributes(env: { "ANTHROPIC_API_KEY" => "invalid-anthropic-key" })
    )
    expect { result.provider_api_key.reload }.to raise_error(ActiveRecord::RecordNotFound)
    expect(account.onboarding_steps.find_by(step: "chat_api_key")).to be_in_progress
  end

  private

  def expect_retry_broadcast_for(chat_session)
    expect(ActionCable.server).to have_received(:broadcast).with(
      "chat_session:#{chat_session.id}",
      hash_including(
        type: "onboarding_retry",
        message: "That API key was rejected. Please try another key.",
        redirect_url: "/onboarding?onboarding_retry=invalid"
      )
    )
  end
end
