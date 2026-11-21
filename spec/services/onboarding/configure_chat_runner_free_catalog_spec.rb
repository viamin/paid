# frozen_string_literal: true

require "rails_helper"

RSpec.describe Onboarding::ConfigureChatRunner do
  let(:account) { create(:account) }
  let(:user) { create(:user, :owner, account:) }

  before do
    Onboarding::StartOnboarding.call(account:)
    Onboarding::CompleteStep.call(account:, step: "account_profile")
  end

  def setup_openrouter
    described_class.call(account:, user:, api_service_type: "openrouter", api_key: "fixture-only")
  end

  # @spec ONBOARD-CHAT-014 ONBOARD-CHAT-003
  it "does not complete free-policy onboarding with an empty free catalog" do
    expect(LlmModel.openrouter_synced_free.active).to be_empty
    expect { setup_openrouter }.to raise_error(ChatSessions::ModelUnavailableError) { |error|
      expect(error.rejection_reasons).to include(:free_model_unavailable)
      expect(error.message).to include("daily catalog")
    }
    expect(user.provider_api_keys.reload).to be_empty
    expect(user.runners.api_key.reload).to be_empty
    expect(account.chat_sessions.reload).to be_empty
    expect(account.onboarding_steps.find_by!(step: "chat_api_key")).to be_in_progress
  end

  # @spec ONBOARD-CHAT-014
  it "does not mistake a tool-ineligible free catalog for working chat" do
    create(:llm_model, :free, model_id: "vendor/not-chat:free", catalog_source: "openrouter_sync",
      supports_tools: false, metadata: { "architecture" => { "output_modalities" => [ "text" ] } })
    expect { setup_openrouter }.to raise_error(ChatSessions::ModelUnavailableError)
    expect(account.chat_sessions.reload).to be_empty
  end

  # @spec ONBOARD-CHAT-014 ONBOARD-CHAT-002
  it "preserves free-policy selection at first use when a Medium free candidate exists" do
    create(:llm_model, :free, model_id: "vendor/chat-mid:free", catalog_source: "openrouter_sync",
      tier: "mid", supports_tools: true, metadata: { "architecture" => { "output_modalities" => [ "text" ] } })
    result = setup_openrouter
    expect(result.runner).to be_free_model_policy
    expect(result.chat_session.model).to be_nil
    expect(account.onboarding_steps.find_by!(step: "chat_api_key")).to be_completed
  end
end
