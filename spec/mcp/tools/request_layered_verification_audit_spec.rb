# frozen_string_literal: true

require "rails_helper"

RSpec.describe Tools::RequestLayeredVerificationAudit do
  let(:account) { create(:account) }
  let(:user) { create(:user, :member, account:) }
  let(:project) { create(:project, account:) }
  let(:session) { create(:chat_session, account:, created_by: user, project:) }
  let(:tool) { described_class.new(user:, session:) }

  before do
    create(:layered_verification_obligation, project:, external_revision: "abc123")
    allow(FeatureFlags).to receive(:enabled?).with(:layered_verification_add_on, project:).and_return(true)
  end

  it "shows the bounded resolved scope and budget before dispatch" do # @spec LAYERED-VERIFY-013 @spec LAYERED-VERIFY-014
    preview = tool.call(project_id: project.id, budget_tokens: 123)

    expect(preview).to include(dispatchable: false, budget_tokens: 123, target_revision: [ "abc123" ])
    expect(preview[:scope]).to contain_exactly(include(identity: be_present))
    expect(AgentRun.where(goal: "layered_verification_audit")).to be_empty
  end

  it "creates an issue-less audit only after confirmation" do # @spec LAYERED-VERIFY-010 @spec LAYERED-VERIFY-013
    result = tool.call(project_id: project.id, confirmed: true)
    run = AgentRun.find(result[:id])

    expect(run).to have_attributes(goal: "layered_verification_audit", issue_id: nil, initiating_user: user)
    expect(run.external_metadata).to include("trigger" => "project_scoped_tool")
  end
end
