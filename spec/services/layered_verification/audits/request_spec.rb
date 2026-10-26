# frozen_string_literal: true

require "rails_helper"

RSpec.describe LayeredVerification::Audits::Request do
  # @spec LAYERED-VERIFY-010 @spec LAYERED-VERIFY-013
  it "creates an issue-less audit with its resolved request snapshot" do
    project = create(:project)
    user = create(:user, account: project.account)
    allow(FeatureFlags).to receive(:enabled?).with(:layered_verification_add_on, project:).and_return(true)
    allow(ProjectPolicy).to receive(:new).with(user, project).and_return(instance_double(ProjectPolicy, manage_issues?: true))
    allow(AgentRuns::RunnerResolver).to receive(:call).with(project:, goal: "layered_verification_audit").and_return([ nil, "codex" ])

    run = described_class.call(
      user:,
      project:,
      obligation_ids: [ "LAYERED-VERIFY-024" ],
      source_references: [ "docs/intent/layered-verification/layered-verification-specs.md" ],
      target_revision: "abc123",
      budget_tokens: 12_000
    )

    expect(run).to have_attributes(goal: "layered_verification_audit", issue: nil, initiating_user: user, status: "queued")
    expect(run.external_metadata.fetch("layered_verification_audit")).to include(
      "obligation_ids" => [ "LAYERED-VERIFY-024" ],
      "source_references" => [ "docs/intent/layered-verification/layered-verification-specs.md" ],
      "target_revision" => "abc123",
      "budget_tokens" => 12_000
    )
  end

  # @spec LAYERED-VERIFY-013
  it "rejects dispatch without a bounded scope, source, revision, and budget" do
    project = create(:project)
    user = create(:user, account: project.account)
    allow(FeatureFlags).to receive(:enabled?).with(:layered_verification_add_on, project:).and_return(true)
    allow(ProjectPolicy).to receive(:new).with(user, project).and_return(instance_double(ProjectPolicy, manage_issues?: true))

    expect {
      described_class.call(user:, project:, obligation_ids: [], source_references: [], target_revision: "", budget_tokens: 0)
    }.to raise_error(described_class::InvalidRequestError, /obligation scope/)
  end
end
