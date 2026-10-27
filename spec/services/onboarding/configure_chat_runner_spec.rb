# frozen_string_literal: true

require "rails_helper"

RSpec.describe Onboarding::ConfigureChatRunner do
  let(:account) { create(:account) }
  let(:user) { create(:user, :owner, account: account) }

  before do
    Onboarding::StartOnboarding.call(account: account)
    Onboarding::CompleteStep.call(account: account, step: "account_profile")
    allow(AgentHarness).to receive(:check_provider).and_return({ status: "ok" })
    RunnerSupport::API_SERVICE_TYPES.keys.excluding("openrouter").each do |service_type|
      create(:llm_model, provider: service_type, model_id: onboarding_model_id(service_type), tier: "low", supports_tools: true)
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

      expect_chat_runner_setup(result, service_type)
    end
  end

  RunnerSupport::API_SERVICE_TYPES.keys.excluding("openrouter").each do |service_type|
    # @spec ONBOARD-CHAT-014 MODEL-AVAILABILITY-008
    it "rolls back #{service_type} onboarding with an actionable catalog reason when no Low model is eligible" do
      LlmModel.find_by!(model_id: onboarding_model_id(service_type)).update!(tier: "mid")

      expect {
        described_class.call(
          account: account,
          user: user,
          api_service_type: service_type,
          api_key: "test-key-#{service_type}"
        )
      }.to raise_error(ChatSessions::Create::NoCompatibleModelError, /catalog_empty/)

      expect(user.provider_api_keys.reload).to be_empty
      expect(user.runners.reload.where("name LIKE ?", "%onboarding%")).to be_empty
      expect(account.chat_sessions.reload).to be_empty
      expect(account.onboarding_steps.find_by(step: "chat_api_key")).to be_in_progress
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

  # @spec ONBOARD-CHAT-003
  it "rejects an authentication failure before persisting a health-checkable key" do
    allow(AgentHarness).to receive(:check_provider).and_return(
      { status: "error", error_category: :authentication, message: "401 Unauthorized" }
    )

    expect {
      described_class.call(account: account, user: user, api_service_type: "openai", api_key: "invalid-key")
    }.to raise_error(Onboarding::ConfigureChatRunner::InvalidApiKeyError, /couldn't verify/i)

    expect(user.provider_api_keys).to be_empty
    expect(user.runners.where("name LIKE ?", "%onboarding%")).to be_empty
    expect(account.onboarding_steps.find_by(step: "chat_api_key")).to be_in_progress
  end

  # @spec ONBOARD-CHAT-003
  it "queues runner-runtime validation for a provider without a proxy health check" do
    expect {
      described_class.call(account: account, user: user, api_service_type: "openrouter", api_key: "test-key")
    }.to have_enqueued_job(Onboarding::ValidateChatApiKeyJob)
  end

  private

  def expect_chat_runner_setup(result, service_type)
    expect(result.provider_api_key.api_service_type).to eq(service_type)
    expect_runner_for_service_type(result.runner, service_type)
    expect(result.runner).to be_enabled_for_chat
    expect(result.runner).to be_api_key
    expect(result.runner.provider_api_key).to eq(result.provider_api_key)
    expect(result.chat_session.runner).to eq(result.runner)
    expect_chat_model_selection(result.chat_session, service_type)
    expect(result.chat_session.title).to eq("Welcome to Paid — let's set you up")
    expect_completed_step(result, service_type)
  end

  def expect_runner_for_service_type(runner, service_type)
    expected_runner_key = RunnerSupport::RUNNER_API_SERVICE_TYPE.key(service_type)
    return expect(runner.runner_key).to eq(expected_runner_key) if expected_runner_key

    expect(runner.runner_key).to be_in(Runner::DIRECT_OUTBOUND_FREE_POLICY_RUNNER_KEYS)
    expect(runner.required_api_service_type).to eq(service_type)
  end

  def expect_completed_step(result, service_type)
    expect(account.onboarding_steps.find_by(step: "chat_api_key")).to have_attributes(
      status: "completed",
      metadata: hash_including(
        "provider_api_key_id" => result.provider_api_key.id,
        "runner_id" => result.runner.id,
        "api_service_type" => service_type
      )
    )
  end

  def onboarding_model_id(service_type)
    "#{service_type}-chat-low"
  end

  def expect_chat_model_selection(chat_session, service_type)
    return expect(chat_session.model).to be_nil if service_type == "openrouter"

    expect(chat_session.model).to eq(onboarding_model_id(service_type))
    expect(chat_session.metadata).to include("model_tier" => "low")
  end
end
