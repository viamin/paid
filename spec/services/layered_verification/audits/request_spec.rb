# frozen_string_literal: true

require "rails_helper"

RSpec.describe LayeredVerification::Audits::Request do
  # @spec LAYERED-VERIFY-010 @spec LAYERED-VERIFY-013 @spec LAYERED-VERIFY-014
  it "creates an issue-less, bounded audit run after resolving its request" do
    project = create(:project)
    actor = create(:user, :owner, account: project.account)
    obligation = create(:layered_verification_obligation, project:)
    resolver = class_double(AgentRuns::RunnerResolver, call: [ nil, "internal_agent" ])
    allow(FeatureFlags).to receive(:enabled?).with(:layered_verification_add_on, project:).and_return(true)
    allow(ProcessRunQueueJob).to receive(:perform_later)

    result = described_class.call(project:, actor:, obligation_ids: [ obligation.id ],
      source_references: [ "docs/intent/payments.md#PAYMENTS-1" ], target_revision: "abc123", budget: 1_000,
      runner_resolver: resolver)

    expect(result.agent_run).to have_attributes(goal: "layered_verification_audit", issue_id: nil,
      initiating_user: actor, trigger_type: "manual")
    expect(result.agent_run.external_metadata.dig("layered_verification_audit", "target_revision")).to eq("abc123")
    expect(ProcessRunQueueJob).to have_received(:perform_later)
  end
end
