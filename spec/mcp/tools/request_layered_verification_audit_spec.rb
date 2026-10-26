# frozen_string_literal: true

require "rails_helper"

RSpec.describe Tools::RequestLayeredVerificationAudit do
  # @spec LAYERED-VERIFY-014
  it "returns the resolved scope before dispatch and creates the audit only after approval" do
    project = create(:project)
    user = create(:user, :member, account: project.account)
    obligation = create(:layered_verification_obligation, project:)
    session = create(:chat_session, project:, account: project.account, created_by: user)
    allow(FeatureFlags).to receive(:enabled?).with(:layered_verification_add_on, project:).and_return(true)
    allow(LayeredVerification::Audits::Request).to receive(:call).and_return(build_stubbed(:agent_run))

    tool = described_class.new(user:, session:)
    preview = tool.dispatch(
      project_id: project.id,
      obligation_ids: [ obligation.id ],
      target_revision: "abc123",
      budget_tokens: 12_000,
      selected_checks: [ check_payload ]
    )

    expect(preview).to include("target_revision" => "abc123", "budget_tokens" => 12_000, "obligation_ids" => [ obligation.id ])
    expect(LayeredVerification::Audits::Request).not_to have_received(:call)

    tool.resolve_confirmation(decision: :approve, pending_result: preview)

    expect(LayeredVerification::Audits::Request).to have_received(:call).with(hash_including(project:, user:, obligations: [ obligation ]))
  end

  def check_payload
    {
      producer: "behavioral_testing", fit: "examples exist", required_inputs: [ "test command" ], assumptions: [],
      resource_expectations: "bounded", residual_gaps: "no model declared"
    }
  end
end
