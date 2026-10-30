# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Settings visible copy" do
  let(:account) { create(:account) }
  let(:user) { create(:user, :owner, account: account) }
  let(:github_token) { create(:github_token, account: account) }
  let(:project) { create(:project, account:, github_token:, created_by: user) }
  let(:runner) { create(:runner, user:, enabled_for_agent_runs: true) }

  before do
    sign_in user
    runner
    allow(Projects::ForkParentPrefill).to receive(:call)
      .and_return(Projects::ForkParentPrefill::Prefill.unavailable("not_stubbed"))
    allow(Projects::Screenshots::RepoConfig).to receive(:call)
      .and_return(Projects::Screenshots::RepoConfig::Result.new(config: {}, content: nil, error: nil))
  end

  # @spec SETTINGS-COPY-001
  it "describes project settings without internal design references" do
    get edit_project_path(project)

    expect(response.body).to include(
      "Provisions a headless browser container on the agent's network so the agent can interactively verify changes via playwright-mcp."
    )
    expect(response.body).to include(
      "waits for a human-applied <code>paid-tests-approved</code> label before implementation begins."
    )

    get project_path(project)

    expect(response.body).to include("e.g. <code>docs/design.md</code>")
    expect(response.body).to include('placeholder="docs/design.md"')
    expect(response.body).not_to match(/RDR-\d+/)
    expect(response.body).not_to include("docs/rdrs/RDR-051.md")
  end

  # @spec SETTINGS-COPY-001
  it "renders tenant chat and feature flag descriptions without internal design references" do
    get edit_tenant_configuration_path

    expect(response.body).to include("Allow the run_shell tool in chat")
    expect(response.body).to include("Provision chat workspace containers in the background")
    expect(response.body).to include("Gate the question-centered chat exploration surfaces.")
    expect(response.body).not_to match(/RDR-\d+/)
  end
end
