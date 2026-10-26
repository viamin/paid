# frozen_string_literal: true

require "rails_helper"

RSpec.describe LayeredVerification::Audits::Request do # @spec LAYERED-VERIFY-010 @spec LAYERED-VERIFY-013
  let(:account) { create(:account) }
  let(:user) { create(:user, :member, account:) }
  let(:project) { create(:project, account:, created_by: user) }
  let!(:obligation) do
    LayeredVerificationObligation.create!(
      project:, framework: "lid", external_identity: "PAYMENT-001", external_revision: "abc123",
      scope_description: "Charge an approved invoice", approval_state: "unresolved"
    )
  end

  before do
    allow(FeatureFlags).to receive(:enabled?).with(:layered_verification_add_on, project:).and_return(true)
    allow(AgentRuns::RunnerResolver).to receive(:call).and_return([ nil, "claude_code" ])
  end

  it "creates an issue-less audit with its resolved scope, sources, revision, budget, and initiator" do
    run = described_class.call(
      project:, user:, obligation_ids: [ obligation.id ], source_references: [ "docs/billing.md:24" ],
      target_revision: "abc123", budget: { "max_tokens" => 4000 }, plan: { "selected_checks" => [] }
    )

    expect(run).to have_attributes(goal: "layered_verification_audit", issue: nil, initiating_user: user)
    expect(run.external_metadata).to include(
      "obligation_ids" => [ obligation.id ], "source_references" => [ "docs/billing.md:24" ],
      "target_revision" => "abc123", "budget" => { "max_tokens" => 4000 }, "waiting_reasons" => []
    )
  end
end
