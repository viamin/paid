# frozen_string_literal: true

require "rails_helper"
require "ostruct"

# @spec ONBOARD-CHAT-005 ONBOARD-CHAT-006 ONBOARD-CHAT-007 ONBOARD-CHAT-008 ONBOARD-CHAT-010
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

  # @spec RUNNER-ZDR-004
  it "includes ZDR declaration provenance without exposing credentials" do
    api_key = create(:provider_api_key, user:, api_service_type: "openrouter")
    runner = create(:runner, user:, runner_key: "opencode", auth_type: "api_key", provider_api_key: api_key, zdr: true,
      config: { "opencode" => { "api_provider" => "openrouter", "model" => "model" } })

    result = Tools::ListRunners.new(user:, session:).call
    listed_runner = result.fetch(:runners).find { |item| item.fetch("id") == runner.id }

    expect(listed_runner.fetch("zdr")).to eq(enabled: true, provenance: "openrouter", runtime_enforcement: "not_verified")
    expect(listed_runner.to_s).not_to include(api_key.api_key)
  end

  it "does not permit another user's provider API key" do
    other = create(:user, :owner, account: create(:account))
    key = create(:provider_api_key, user: other)
    allow(RunnerSupport).to receive(:addable_runner_keys).and_return([ "cursor" ])

    expect {
      Tools::CreateRunner.new(user:, session:).call(name: "Cursor", runner_key: "cursor", auth_type: "api_key", provider_api_key_id: key.id, confirmed: true)
    }.to raise_error(ActiveRecord::RecordNotFound)
  end

  it "creates an account-level tracker configuration" do
    result = Tools::CreateTrackerConfiguration.new(user:, session:).call(
      tracker_type: "github_issues", configurable_type: "Account", confirmed: true
    )

    expect(result).to include("tracker_type" => "github_issues", "configurable_type" => "Account")
  end

  it "returns the credential setup route for an OAuth tracker" do
    result = Tools::CreateTrackerConfiguration.new(user:, session:).call(
      tracker_type: "jira", configurable_type: "Account", confirmed: true
    )

    expect(result).to eq(status: "connect_required", connect_url: "/integration_credentials/new?service_key=jira")
  end

  it "does not complete a pending first-project step when creating a project" do
    Onboarding::StartOnboarding.call(account:)
    github_token = create(:github_token, account:)
    client = instance_double(GithubClient, repository: OpenStruct.new(
      id: 1, name: "paid", default_branch: "main", language: "Ruby"
    ))
    allow(GithubClient).to receive(:new).and_return(client)

    Tools::CreateProject.new(user:, session:).call(
      mode: "connect_existing", owner: "viamin", repo: "paid", github_token_id: github_token.id, confirmed: true
    )

    expect(account.onboarding_steps.find_by!(step: "first_project")).to be_pending
  end

  it "resolves the owner from a GitHub token when connecting a project" do
    github_token = create(:github_token, account:)
    client = instance_double(GithubClient, authenticated_login: "viamin", repository: OpenStruct.new(
      id: 1, name: "paid", default_branch: "main", language: "Ruby"
    ))
    allow(GithubClient).to receive(:new).and_return(client)

    result = Tools::CreateProject.new(user:, session:).call(
      mode: "connect_existing", repo: "paid", github_token_id: github_token.id, confirmed: true
    )

    expect(result).to include("owner" => "viamin", "repo" => "paid")
    expect(client).to have_received(:repository).with("viamin/paid")
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
