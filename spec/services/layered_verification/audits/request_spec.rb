# frozen_string_literal: true

require "rails_helper"

RSpec.describe LayeredVerification::Audits::Request do
  # @spec LAYERED-VERIFY-010 @spec LAYERED-VERIFY-013 @spec LAYERED-VERIFY-021
  it "creates an issue-less, provenance-bearing audit run after authorization" do
    project = create(:project)
    user = create(:user, :owner, account: project.account)
    obligation = create(:layered_verification_obligation, project: project)
    allow(FeatureFlags).to receive(:enabled?).with(:layered_verification_add_on, project:).and_return(true)
    allow(AgentRuns::RunnerResolver).to receive(:call).and_return([ nil, "claude_code" ])
    allow(ProcessRunQueueJob).to receive(:perform_later)

    run = described_class.call(
      project:, user:, obligation_ids: [ obligation.id ], source_references: [ "docs/intent/payments.md" ],
      target_revision: "abc123", budget: { "max_tokens" => 500 },
      checks: [ { producer: "behavioral_testing", fit: "scenario", required_inputs: [], assumptions: [], resource_expectations: {}, limitations: "bounded" } ],
      omissions: [], residual_gaps: []
    )

    expect(run).to have_attributes(issue: nil, goal: "layered_verification_audit", initiating_user: user, status: "queued")
    expect(run.external_metadata.fetch("layered_verification_audit")).to include(
      "target_revision" => "abc123", "source_references" => [ "docs/intent/payments.md" ], "budget" => { "max_tokens" => 500 }
    )
  end
end
