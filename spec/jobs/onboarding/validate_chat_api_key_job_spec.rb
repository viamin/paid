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
    Runner::DIRECT_OUTBOUND_SERVICE_TYPES.excluding("openrouter").each do |service_type|
      create(:llm_model, provider: service_type)
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

    described_class.perform_now(result.runner.id)

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
end
