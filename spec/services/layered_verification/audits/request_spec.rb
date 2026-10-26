# frozen_string_literal: true

require "rails_helper"

RSpec.describe LayeredVerification::Audits::Request do
  # @spec LAYERED-VERIFY-010 @spec LAYERED-VERIFY-013
  it "creates an issue-less audit run with its bounded scope and provenance" do
    project = create(:project)
    actor = project.created_by
    obligation = create(:layered_verification_obligation, project:)
    allow(FeatureFlags).to receive(:enabled?).with(:layered_verification_add_on, project:).and_return(true)
    allow(LayeredVerification::AuditAccess).to receive(:authorize!).with(user: actor, project:).and_return(true)
    runner = create(:runner, user: project.created_by)
    allow(AgentRuns::RunnerResolver).to receive(:call).with(project:, goal: "layered_verification_audit").and_return([ runner.id, "claude_code" ])

    run = described_class.call(project:, actor:, obligation_ids: [ obligation.id ], target_revision: "abc123", budget: 400)

    expect(run).to have_attributes(goal: "layered_verification_audit", issue_id: nil, base_commit_sha: "abc123")
    expect(run.external_metadata).to include("obligation_ids" => [ obligation.id ], "budget" => 400, "initiated_by_id" => actor.id)
  end
end
