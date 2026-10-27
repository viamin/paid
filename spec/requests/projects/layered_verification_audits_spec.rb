# frozen_string_literal: true

require "rails_helper"
require "ostruct"

RSpec.describe "Layered verification audits" do
  let(:account) { create(:account) }
  let(:user) { create(:user, :owner, account:) }
  let(:project) { create(:project, account:, created_by: user) }
  let(:obligation) do
    create(
      :layered_verification_obligation,
      project:,
      scope_description: "Checkout behavior",
      external_identity: "docs/checkout.md"
    )
  end
  let(:github_client) { instance_double(GithubClient) }

  before do
    sign_in user
    allow(FeatureFlags).to receive(:enabled?).with(:layered_verification_add_on, project:).and_return(true)
    allow(GithubClient).to receive(:new).and_return(github_client)
    allow(github_client).to receive(:ref).with(project.full_name, "main")
      .and_return(OpenStruct.new(object: OpenStruct.new(sha: "a" * 40)))
  end

  # @spec LAYERED-VERIFY-010 LAYERED-VERIFY-013 LAYERED-VERIFY-014
  it "renders the project audit preview and queues only its confirmed request" do
    request_parameters = {
      obligation_ids: [ obligation.id ],
      target_revision: "main",
      budget: { max_minutes: 15 }
    }

    expect {
      post request_layered_verification_audit_project_agent_runs_path(project), params: request_parameters
    }.not_to change { project.agent_runs.where(goal: "layered_verification_audit").count }

    expect(response).to have_http_status(:ok)
    expect(response.body).to include(
      "Verification audit preview",
      "Checkout behavior",
      "#{'a' * 40}",
      "15"
    )
    expect(response.body).to match(/name="confirmed"[^>]*value="true"/)

    expect {
      post request_layered_verification_audit_project_agent_runs_path(project),
        params: request_parameters.merge(confirmed: true)
    }.to change { project.agent_runs.where(goal: "layered_verification_audit").count }.by(1)

    expect(response).to redirect_to(project_agent_run_path(project, project.agent_runs.last))
  end

  # @spec LAYERED-VERIFY-014
  it "exposes the audit request control on the project page only when available" do
    get project_path(project)

    expect(response.body).to include(request_layered_verification_audit_project_agent_runs_path(project))

    allow(FeatureFlags).to receive(:enabled?).with(:layered_verification_add_on, project:).and_return(false)

    get project_path(project)

    expect(response.body).not_to include(request_layered_verification_audit_project_agent_runs_path(project))
  end
end
