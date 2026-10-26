# frozen_string_literal: true

require "rails_helper"

RSpec.describe Tools::RequestLayeredVerificationAudit do
  # @spec LAYERED-VERIFY-014
  it "uses the shared audit request path" do
    project = create(:project)
    user = create(:user, account: project.account)
    create(:project_membership, :member, user:, project:)
    obligation = create(:layered_verification_obligation, project:)
    session = instance_double(ChatSession)
    run = build(:agent_run, project:, issue: nil, goal: "layered_verification_audit")

    expect(LayeredVerification::Audits::Request).to receive(:call).with(
      project:, user:, obligation_ids: [ obligation.id ], target_revision: "b" * 40, budget_tokens: 500
    ).and_return(run)

    result = described_class.new(user:, session:).dispatch(
      project_id: project.id, obligation_ids: [ obligation.id ], target_revision: "b" * 40,
      budget_tokens: 500, confirmed: true
    )

    expect(result).to include(id: run.id, goal: "layered_verification_audit")
  end
end
