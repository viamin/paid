# frozen_string_literal: true

require "rails_helper"

RSpec.describe "onboarding chat tools" do
  let(:account) { create(:account) }
  let(:user) { create(:user, :owner, account:) }
  let(:session) { create(:chat_session, account:, created_by: user) }

  it "reports setup state without exposing credentials" do
    create(:onboarding_step, account:, step: "account_profile", status: "completed")
    create(:github_token, account:)

    result = Tools::GetOnboardingStatus.new(user:, session:).call
    capabilities = Tools::GetAccountCapabilities.new(user:, session:).call

    expect(result[:checklist]).to include(github_credential: true)
    expect(capabilities[:github_tokens].first).not_to have_key("token")
  end

  it "requires confirmation before completing an onboarding step" do
    create(:onboarding_step, account:, step: "account_profile")

    expect {
      Tools::CompleteOnboardingStep.new(user:, session:).call(step: "account_profile", confirmed: false)
    }.to raise_error(ArgumentError, /Confirmation required/)
  end

  it "does not permit another user's provider API key" do
    other = create(:user, :owner, account: create(:account))
    key = create(:provider_api_key, user: other)
    allow(RunnerSupport).to receive(:addable_runner_keys).and_return([ "cursor" ])

    expect {
      Tools::CreateRunner.new(user:, session:).call(name: "Cursor", runner_key: "cursor", auth_type: "api_key", provider_api_key_id: key.id, confirmed: true)
    }.to raise_error(ActiveRecord::RecordNotFound)
  end

  it "strips confirmation from onboarding write tools advertised to chat" do
    definitions = Tools::Registry.chat_definitions_for(user:, session:)

    %w[create_runner create_tracker_configuration create_project complete_onboarding_step].each do |name|
      expect(definitions.find { |definition| definition[:name] == name }.dig(:inputSchema, :properties)).not_to have_key(:confirmed)
    end
  end

  it "searches only the curated product docs corpus" do
    result = Tools::GetProductDocs.new(user:, session:).call(topic: "auto_merge")

    expect(result).to include(include("topic" => "auto_merge", "content" => a_string_including("Auto-merge")))
  end
end
