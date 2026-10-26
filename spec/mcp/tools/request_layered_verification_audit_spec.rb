# frozen_string_literal: true

require "rails_helper"

RSpec.describe Tools::RequestLayeredVerificationAudit do
  let(:user) { create(:user) }
  let(:project) { create(:project, account: user.account) }
  let(:session) { create(:chat_session, account: user.account, user:) }

  # @spec LAYERED-VERIFY-013
  # @spec LAYERED-VERIFY-014
  it "creates an issue-less audit run with resolved scope and budget" do
    allow(FeatureFlags).to receive(:enabled?).with(:layered_verification_add_on, project:).and_return(true)
    allow(ProjectPolicy).to receive(:new).with(user, project).and_return(instance_double(ProjectPolicy, manage_issues?: true))
    allow(AgentRuns::RunnerResolver).to receive(:call).and_return([ nil, "codex" ])

    result = described_class.new(user:, session:).call(project_id: project.id, scope: "billing", target_revision: "abc123", budget: 5000, confirmed: true)

    run = AgentRun.find(result.fetch(:id))
    expect(run).to have_attributes(goal: "layered_verification_audit", issue_id: nil, initiating_user: user)
    expect(run.external_metadata).to include("scope" => "billing", "target_revision" => "abc123", "budget" => 5000)
  end
end
