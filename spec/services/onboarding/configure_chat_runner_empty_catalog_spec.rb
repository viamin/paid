# frozen_string_literal: true

require "rails_helper"

RSpec.describe Onboarding::ConfigureChatRunner do
  let(:account) { create(:account) }
  let(:user) { create(:user, :owner, account:) }

  before do
    Onboarding::StartOnboarding.call(account:)
    Onboarding::CompleteStep.call(account:, step: "account_profile")
    allow(AgentHarness).to receive(:check_provider).and_return(status: "ok")
  end

  RunnerSupport::API_SERVICE_TYPES.keys.excluding("openrouter").each do |provider|
    # @spec ONBOARD-CHAT-014 ONBOARD-CHAT-002
    it "bootstraps #{provider} with an eligible Medium model when Low is absent" do
      model = create(:llm_model, provider:, model_id: "#{provider}-only-mid", tier: "mid", supports_tools: true)

      result = described_class.call(account:, user:, api_service_type: provider, api_key: "fixture-only")

      expect(result.chat_session.model).to eq(model.model_id)
      expect(result.chat_session.metadata).to include(
        "model_tier" => "mid", "model_substitution_reason" => "preferred_tier_unavailable"
      )
      expect(account.onboarding_steps.find_by!(step: "chat_api_key")).to be_completed
    end

    # @spec ONBOARD-CHAT-014 ONBOARD-CHAT-003
    it "returns structured catalog recovery for #{provider} without a partial setup" do
      expect(LlmModel.active.by_provider(provider)).to be_empty
      expect do
        described_class.call(account:, user:, api_service_type: provider, api_key: "fixture-only")
      end.to raise_error(ChatSessions::ModelUnavailableError) { |error|
        expect(error.rejection_reasons).to include(:catalog_empty)
        expect(error.message).to include("refresh the catalog or contact your administrator")
      }
      user.reload
      account.reload
      expect(user.provider_api_keys).to be_empty
      expect(user.runners.api_key).to be_empty
      expect(account.chat_sessions).to be_empty
      expect(account.onboarding_steps.find_by!(step: "chat_api_key")).to be_in_progress
    end
  end
  # @spec ONBOARD-CHAT-003 ONBOARD-CHAT-014
  it "rolls back bootstrap when a caller handles rejection inside another transaction" do
    ActiveRecord::Base.transaction(requires_new: true) do
      expect do
        described_class.call(account:, user:, api_service_type: "openai", api_key: "fixture-only")
      end.to raise_error(ChatSessions::ModelUnavailableError)

      expect(user.provider_api_keys.reload).to be_empty
      expect(user.runners.api_key.reload).to be_empty
      expect(account.chat_sessions.reload).to be_empty
      expect(account.onboarding_steps.find_by!(step: "chat_api_key")).to be_in_progress
    end
  end
end
