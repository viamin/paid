# frozen_string_literal: true

require "rails_helper"

# @spec ONBOARD-CHAT-005 ONBOARD-CHAT-008 ONBOARD-CHAT-010
RSpec.describe Tools::CompleteOnboardingStep do
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
    create(:onboarding_step, :in_progress, account:, step: "account_profile")

    expect {
      described_class.new(user:, session:).call(step: "account_profile", confirmed: false)
    }.to raise_error(ArgumentError, /Confirmation required/)
  end

  it "allows an account member to complete a configured onboarding step" do
    member = create(:user, :member, account:)
    create(:onboarding_step, :in_progress, account:, step: "account_profile")

    result = described_class.new(user: member, session:).call(step: "account_profile", confirmed: true)

    expect(result.fetch("status")).to eq("completed")
  end

  it "does not fast-forward default configuration without all setup prerequisites" do
    create(:onboarding_step, :in_progress, account:, step: "configure_defaults")

    expect {
      described_class.new(user:, session:).call(
        step: "configure_defaults", confirmed: true, metadata: { "operating_posture" => "standard" }
      )
    }.to raise_error(ArgumentError, /before configuring defaults/)

    expect(account.reload.onboarding_completed_at).to be_nil
  end

  it "applies the selected default posture before completing setup" do
    create(:onboarding_step, account:, step: "account_profile", status: "completed")
    create(:onboarding_step, account:, step: "github_token", status: "completed")
    create(:onboarding_step, account:, step: "first_project", status: "completed")
    create(:onboarding_step, :in_progress, account:, step: "configure_defaults")
    create(:github_token, account:)
    create(:project, account:)
    create(:runner, user:, enabled_for_chat: true, enabled_for_agent_runs: true)

    result = described_class.new(user:, session:).call(
      step: "configure_defaults", confirmed: true, metadata: { "operating_posture" => "standard" }
    )

    expect(result.fetch("metadata")).to include("operating_posture" => "standard")
    expect(account.reload.onboarding_completed_at).to be_present
  end

  it "includes each runner's batched health state and last quota check" do
    runner = create(:runner, user:)
    checked_at = 5.minutes.ago.change(usec: 0)
    create(:runner_state, :rate_limited, user:, runner_name: runner.state_key, metadata: {
      "quota_status" => { "available" => true, "checked_at" => checked_at.iso8601 }
    })

    result = Tools::ListRunners.new(user:, session:).call

    listed_runner = result.fetch(:runners).find { |item| item.fetch("id") == runner.id }
    expect(listed_runner).to include("health" => "rate_limited", "last_checked_at" => checked_at)
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
