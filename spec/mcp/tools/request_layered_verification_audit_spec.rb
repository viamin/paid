# frozen_string_literal: true

require "rails_helper"

RSpec.describe Tools::RequestLayeredVerificationAudit do
  # @spec LAYERED-VERIFY-013 @spec LAYERED-VERIFY-014
  it "creates an issue-less audit with its resolved scope, revision, budget, and initiator" do
    user = create(:user)
    project = create(:project, account: user.account)
    allow(FeatureFlags).to receive(:enabled?).with(:layered_verification_add_on, project:).and_return(true)
    allow(ProjectPolicy).to receive(:new).with(user, project).and_return(instance_double(ProjectPolicy, manage_issues?: true))
    allow(AgentRuns::RunnerResolver).to receive(:call).and_return([ nil, "internal_agent" ])
    allow(ProcessRunQueueJob).to receive(:perform_later)

    result = described_class.new(user:, session: nil).call(
      project_id: project.id, scope: "payment capture", sources: [ "docs/payments.md" ],
      target_revision: "abc123", budget: 5000,
      checks: [ { producer: "behavioral_testing", fit: "Exercises payment capture" } ], confirmed: true
    )

    run = AgentRun.find(result.fetch(:id))
    expect(run).to have_attributes(goal: "layered_verification_audit", issue: nil, initiating_user: user)
    expect(run.external_metadata).to include("resolved_scope" => "payment capture", "target_revision" => "abc123", "budget" => 5000)
  end
end
