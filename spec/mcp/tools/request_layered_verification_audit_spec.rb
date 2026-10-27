# frozen_string_literal: true

require "rails_helper"
require "ostruct"

RSpec.describe Tools::RequestLayeredVerificationAudit do
  let(:account) { create(:account) }
  let(:user) { create(:user, :owner, account:) }
  let(:project) { create(:project, account:) }
  let(:session) { create(:chat_session, account:, created_by: user, project:) }
  let(:obligation) { create(:layered_verification_obligation, project:) }
  let(:tool) { described_class.new(user:, session:) }
  let(:github_client) { instance_double(GithubClient) }
  let(:selections) do
    {
      obligation.id => {
        selected_checks: [ "spec_to_code" ],
        fit: "mapped specification",
        exclusions: [ "no formal model" ]
      }
    }
  end

  before do
    allow(FeatureFlags).to receive(:enabled?).with(:layered_verification_add_on, project:).and_return(true)
    allow(GithubClient).to receive(:new).and_return(github_client)
    allow(github_client).to receive(:ref).with(project.full_name, "abc123")
      .and_return(OpenStruct.new(object: OpenStruct.new(sha: "abc123")))
  end

  # @spec LAYERED-VERIFY-014 LAYERED-VERIFY-021
  it "previews before human confirmation and creates a run only when confirmed" do
    preview = tool.dispatch(**audit_arguments)

    expect(preview.fetch("plan")).to have_key(obligation.id.to_s)
    expect(AgentRun.where(goal: "layered_verification_audit")).to be_empty

    result = tool.dispatch(**audit_arguments.merge(confirmed: true))
    run = AgentRun.find(result.fetch(:id))
    stored_plan = run.external_metadata.dig("layered_verification", "plan", obligation.id.to_s)

    expect(stored_plan).to include(
      "selected_checks" => [ "spec_to_code" ],
      "fit" => "mapped specification",
      "exclusions" => [ "no formal model" ]
    )
  end

  # @spec LAYERED-VERIFY-014
  it "rejects an unresolvable target revision before dispatch" do
    allow(github_client).to receive(:ref).with(project.full_name, "missing")
      .and_raise(GithubClient::NotFoundError)

    expect {
      tool.dispatch(
        project_id: project.id, obligation_ids: [ obligation.id ], target_revision: "missing",
        budget: {}, confirmed: true
      )
    }.to raise_error(LayeredVerification::Audits::Request::InvalidTargetRevisionError, "target revision could not be resolved")
  end

  def audit_arguments
    {
      project_id: project.id,
      obligation_ids: [ obligation.id ],
      target_revision: "abc123",
      budget: { max_minutes: 15 },
      selections:
    }
  end
end
