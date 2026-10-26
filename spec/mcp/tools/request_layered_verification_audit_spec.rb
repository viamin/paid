# frozen_string_literal: true

require "rails_helper"

RSpec.describe Tools::RequestLayeredVerificationAudit do
  # @spec LAYERED-VERIFY-013
  # @spec LAYERED-VERIFY-014
  it "creates an issue-less audit run with the resolved scope, sources, revision, and budget" do
    user = create(:user)
    project = create(:project, account: user.account, created_by: user)
    allow(FeatureFlags).to receive(:enabled?).with(:layered_verification_add_on, project:).and_return(true)

    result = described_class.new(user:, session: nil).dispatch(
      project_id: project.id,
      scope: "checkout refunds",
      sources: [ "docs/intent/payments/specs.md" ],
      target_revision: "abc123",
      budget: 12_000,
      confirmed: true
    )

    run = AgentRun.find(result.fetch(:id))
    expect(run).to have_attributes(goal: "layered_verification_audit", issue: nil, initiating_user: user)
    expect(run.external_metadata).to include("scope" => "checkout refunds", "sources" => [ "docs/intent/payments/specs.md" ], "target_revision" => "abc123", "budget" => 12_000)
  end
end
