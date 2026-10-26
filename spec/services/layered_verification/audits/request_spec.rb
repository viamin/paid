# frozen_string_literal: true

require "rails_helper"

RSpec.describe LayeredVerification::Audits::Request do
  # @spec LAYERED-VERIFY-010, LAYERED-VERIFY-013
  it "creates an issue-less audit run with its resolved scope and budget" do
    project = create(:project)
    user = create(:user, :owner, account: project.account)
    obligation = create(:layered_verification_obligation, project:)
    allow(FeatureFlags).to receive(:enabled?).with(:layered_verification_add_on, project:).and_return(true)
    allow(AgentRuns::RunnerResolver).to receive(:call).and_return([ nil, "codex" ])
    allow(ProcessRunQueueJob).to receive(:perform_later)

    run = described_class.call(user:, project:, obligation_ids: [ obligation.id ], target_revision: "abc123", budget: 5000)

    expect(run).to have_attributes(goal: "layered_verification_audit", issue: nil, initiating_user: user)
    expect(run.external_metadata.dig("layered_verification", "budget")).to eq(5000)
  end
end
