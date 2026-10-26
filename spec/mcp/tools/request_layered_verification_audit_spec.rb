# frozen_string_literal: true

require "rails_helper"

RSpec.describe Tools::RequestLayeredVerificationAudit do
  # @spec LAYERED-VERIFY-012 @spec LAYERED-VERIFY-014
  it "uses the shared audit request boundary and returns the dispatch preview" do
    project = create(:project)
    user = create(:user, :member, account: project.account)
    obligation = create(:layered_verification_obligation, project:)
    run = build(:agent_run, project:, initiating_user: user, goal: "layered_verification_audit")
    allow(LayeredVerification::Audits::Request).to receive(:call).and_return(run)

    result = described_class.new(user:, session: nil).dispatch(
      project_id: project.id,
      obligation_ids: [ obligation.id ],
      source_references: [ "docs/intent/orders.md#refunds" ],
      target_revision: "code-sha",
      budget_tokens: 12_000,
      confirmed: true
    )

    expect(result).to include(id: run.id, goal: "layered_verification_audit", status: run.status)
    expect(LayeredVerification::Audits::Request).to have_received(:call).with(
      user:, project:, obligation_ids: [ obligation.id ], source_references: [ "docs/intent/orders.md#refunds" ],
      target_revision: "code-sha", budget_tokens: 12_000
    )
  end
end
