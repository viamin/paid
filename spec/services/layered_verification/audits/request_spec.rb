# frozen_string_literal: true

require "rails_helper"

RSpec.describe LayeredVerification::Audits::Request do
  let(:project) { create(:project) }
  let(:user) { create(:user, account: project.account) }
  let(:obligation) { create(:layered_verification_obligation, project:, external_identity: "PAYMENTS-001") }

  # @spec LAYERED-VERIFY-013 @spec LAYERED-VERIFY-021
  it "creates an issue-less audit with its resolved scope, revision, budget, and initiating user" do
    allow(AgentRuns::RunnerResolver).to receive(:call).and_return([ nil, "codex" ])
    allow(ProcessRunQueueJob).to receive(:perform_later)

    run = described_class.call(**request_attributes)

    expect(run).to be_persisted
    expect(run).to have_attributes(goal: "layered_verification_audit", issue: nil, initiating_user: user, trigger_type: "manual")
    expect(run.external_metadata).to include(
      "layered_verification" => include(
        "obligation_ids" => [ obligation.id ],
        "target_revision" => "abc123",
        "budget_tokens" => 12_000
      )
    )
    expect(ProcessRunQueueJob).to have_received(:perform_later)
  end

  def request_attributes
    { project:, user:, obligations: [ obligation ], target_revision: "abc123", budget_tokens: 12_000,
      plan: { "selected_checks" => [ { "producer" => "behavioral_testing", "fit" => "declared examples" } ], "omissions" => [] } }
  end
end
