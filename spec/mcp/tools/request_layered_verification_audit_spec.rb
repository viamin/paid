# frozen_string_literal: true

require "rails_helper"

RSpec.describe Tools::RequestLayeredVerificationAudit do
  # @spec LAYERED-VERIFY-010 @spec LAYERED-VERIFY-013 @spec LAYERED-VERIFY-014
  it "creates an issue-less audit run through the dedicated, flag-gated tool" do
    project = create(:project)
    user = create(:user, :member, account: project.account)
    session = create(:chat_session, account: project.account, created_by: user, project: project)
    obligation = create(:layered_verification_obligation, project:)
    allow(FeatureFlags).to receive(:enabled?).with(:layered_verification_add_on, project:).and_return(true)

    result = described_class.new(user:, session:).call(
      project_id: project.id, obligation_ids: [ obligation.id ], target_revision: "abc123", budget_tokens: 1000,
      selected_checks: [ { producer: "behavioral_testing", fit: "Exercises the bounded scenario", required_inputs: [], assumptions: [], resource_expectations: "small", residual_gaps: [] } ], confirmed: true
    )

    run = AgentRun.find(result[:id])
    expect(run).to have_attributes(goal: "layered_verification_audit", issue_id: nil, initiating_user: user)
    expect(run.external_metadata.dig("layered_verification", "target_revision")).to eq("abc123")
  end
end
