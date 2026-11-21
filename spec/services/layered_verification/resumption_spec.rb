# frozen_string_literal: true

require "rails_helper"

RSpec.describe LayeredVerification::Resumption do
  # @spec LAYERED-VERIFY-020
  it "admits an interrupted audit only after current authorization, approval, budget, and freshness checks" do
    user = create(:user, :owner)
    project = create(:project, account: user.account)
    obligation = create(:layered_verification_obligation, project:, approval_state: "approved",
      external_revision: "intent-v1", approved_revision_reference: "docs/intent/payment.md")
    run = create(:agent_run, project:, initiating_user: user, goal: "layered_verification_audit", status: "cancelled",
      external_metadata: { "layered_verification" => { "obligation_ids" => [ obligation.id ], "target_revision" => "code-v1",
        "budget" => { "max_minutes" => 5 }, "dependencies" => { "environment" => "ruby-3.4" } } })
    result = create(:layered_verification_check_result, obligation:, agent_run: run, input_revision: {
      "code" => "code-v1", "external_revision" => "intent-v1", "dependencies" => { "environment" => "ruby-3.4" }
    })
    allow(FeatureFlags).to receive(:enabled?).with(:layered_verification_add_on, project:).and_return(true)

    decision = described_class.call(agent_run: run, user:)

    expect(decision).to be_admitted
    expect(decision.reusable_result_ids).to eq([ result.id ])
    expect(decision.replay_repair_mutation?).to be(false)
  end
end
