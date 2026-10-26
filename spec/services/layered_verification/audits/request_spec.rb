# frozen_string_literal: true

require "rails_helper"

RSpec.describe LayeredVerification::Audits::Request do
  # @spec LAYERED-VERIFY-010
  # @spec LAYERED-VERIFY-013
  it "creates an issue-less manual run with its resolved scope and budget" do
    project = create(:project)
    actor = create(:user, account: project.account)
    obligation = create(:layered_verification_obligation, project:)
    allow(FeatureFlags).to receive(:enabled?).with(:layered_verification_add_on, project:).and_return(true)
    allow_any_instance_of(ProjectPolicy).to receive(:manage_issues?).and_return(true)
    allow(AgentRuns::RunnerResolver).to receive(:call).and_return([ nil, "codex" ])
    allow(ProcessRunQueueJob).to receive(:perform_later)

    run = described_class.call(project:, actor:, obligation_ids: [ obligation.id ], revision: "abc123", budget_cents: 25)

    expect(run).to have_attributes(goal: "layered_verification_audit", issue: nil, cost_cents: 25)
    expect(run.external_metadata.dig("layered_verification_audit", "target_revision")).to eq("abc123")
  end
end
