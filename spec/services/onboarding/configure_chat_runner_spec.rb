# frozen_string_literal: true

require "rails_helper"

RSpec.describe Onboarding::ConfigureChatRunner do
  let(:account) { create(:account) }
  let(:user) { create(:user, :owner, account: account) }

  before do
    Onboarding::StartOnboarding.call(account: account)
    Onboarding::CompleteStep.call(account: account, step: "account_profile")
    Runner::DIRECT_OUTBOUND_SERVICE_TYPES.excluding("openrouter").each do |service_type|
      create(:llm_model, provider: service_type)
    end
  end

  RunnerSupport::API_SERVICE_TYPES.each_key do |service_type|
    # @spec ONBOARD-CHAT-002
    it "creates a compatible chat runner for #{service_type}" do
      result = described_class.call(
        account: account,
        user: user,
        api_service_type: service_type,
        api_key: "test-key-#{service_type}"
      )

      expect(result.provider_api_key.api_service_type).to eq(service_type)
      expect(result.runner).to be_enabled_for_chat
      expect(result.runner).to be_api_key
      expect(result.runner.provider_api_key).to eq(result.provider_api_key)
      expect(result.chat_session.runner).to eq(result.runner)
      expect(result.chat_session.title).to eq("Welcome to Paid — let's set you up")
      expect(account.onboarding_steps.find_by(step: "chat_api_key")).to have_attributes(
        status: "completed",
        metadata: hash_including(
          "provider_api_key_id" => result.provider_api_key.id,
          "runner_id" => result.runner.id,
          "api_service_type" => service_type
        )
      )
    end
  end

  # @spec ONBOARD-CHAT-002
  it "uses OpenRouter's free model policy" do
    result = described_class.call(account: account, user: user, api_service_type: "openrouter", api_key: "test-key")

    expect(result.runner).to be_free_model_policy
    expect(result.runner.config.dig(result.runner.runner_key, "api_provider")).to eq("openrouter")
  end

  # @spec ONBOARD-CHAT-003
  it "does not persist a partial setup when the key is invalid" do
    expect {
      described_class.call(account: account, user: user, api_service_type: "openrouter", api_key: "")
    }.to raise_error(ActiveRecord::RecordInvalid)

    expect(user.provider_api_keys).to be_empty
    expect(user.runners.where("name LIKE ?", "%onboarding%")).to be_empty
    expect(account.chat_sessions).to be_empty
    expect(account.onboarding_steps.find_by(step: "chat_api_key")).to be_in_progress
  end
end
