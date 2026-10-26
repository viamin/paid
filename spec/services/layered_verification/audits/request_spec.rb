# frozen_string_literal: true

require "rails_helper"

RSpec.describe LayeredVerification::Audits::Request do
  # @spec LAYERED-VERIFY-010 @spec LAYERED-VERIFY-013 @spec LAYERED-VERIFY-021
  it "queues an issue-less, bounded audit with its resolved scope and provenance" do
    project = create(:project)
    user = create(:user, account: project.account)
    create(:account_membership, :member, account: project.account, user:)
    obligation = create(:layered_verification_obligation, project:)
    allow(FeatureFlags).to receive(:enabled?).with(:layered_verification_add_on, project:).and_return(true)
    allow(AgentRuns::RunnerResolver).to receive(:call).and_return([ nil, "codex" ])

    run = described_class.call(project:, user:, obligation_ids: [ obligation.id ], budget_tokens: 5000)

    expect(run).to have_attributes(goal: "layered_verification_audit", issue: nil, initiating_user: user)
    expect(run.external_metadata).to include("obligation_ids" => [ obligation.id ], "budget_tokens" => 5000)
  end
end
