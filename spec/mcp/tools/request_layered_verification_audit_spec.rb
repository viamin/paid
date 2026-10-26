# frozen_string_literal: true

require "rails_helper"

RSpec.describe Tools::RequestLayeredVerificationAudit do
  # @spec LAYERED-VERIFY-010 @spec LAYERED-VERIFY-013 @spec LAYERED-VERIFY-014
  it "creates an issue-less audit run with its resolved dispatch record" do
    project = create(:project)
    user = create(:user, account: project.account)
    create(:account_membership, :owner, user:, account: project.account)
    obligation = create(:layered_verification_obligation, project: project)
    allow(FeatureFlags).to receive(:enabled?).with(:layered_verification_add_on, project:).and_return(true)
    allow(AgentRuns::RunnerResolver).to receive(:call).and_return([ nil, "codex" ])
    allow(ProcessRunQueueJob).to receive(:perform_later)

    result = described_class.new(user:, session: nil).call(
      project_id: project.id,
      obligation_ids: [ obligation.id ],
      source_references: [ "docs/intent/example.md" ],
      target_revision: "abc123",
      budget_tokens: 500,
      confirmed: true
    )

    run = AgentRun.find(result.fetch(:id))
    expect(run).to have_attributes(goal: "layered_verification_audit", issue: nil, initiating_user: user)
    expect(run.external_metadata.dig("layered_verification", "target_revision")).to eq("abc123")
    expect(result.fetch(:dispatch)).to include("budget_tokens" => 500, "obligation_ids" => [ obligation.id ])
  end
end
