# frozen_string_literal: true

require "rails_helper"

RSpec.describe Tools::RequestLayeredVerificationAudit do
  # @spec LAYERED-VERIFY-012 @spec LAYERED-VERIFY-014
  it "uses the feature-gated audit boundary and returns a dispatch preview" do
    project = create(:project)
    user = create(:user, :member, account: project.account)
    session = create(:chat_session, account: project.account, created_by: user, project: project)
    obligation = create(:layered_verification_obligation, project:)
    allow(FeatureFlags).to receive(:enabled?).with(:layered_verification_add_on, project:).and_return(true)
    allow(AgentRuns::RunnerResolver).to receive(:call).and_return([ nil, "codex" ])

    result = described_class.new(user:, session:).call(
      project_id: project.id,
      obligation_ids: [ obligation.id ],
      sources: [ "docs/intent/payments" ],
      target_revision: "abc123",
      budget: { "max_tokens" => 1000 },
      confirmed: true
    )

    expect(result).to include(goal: "layered_verification_audit", issue_id: nil)
    expect(AgentRun.find(result[:id]).external_metadata).to include("target_revision" => "abc123")
  end
end
