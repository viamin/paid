# frozen_string_literal: true

require "rails_helper"

RSpec.describe LayeredVerification::Audits::Request do
  # @spec LAYERED-VERIFY-010 @spec LAYERED-VERIFY-013
  it "creates an issue-less, bounded audit run with its resolved request snapshot" do
    project = create(:project)
    user = create(:user, account: project.account)
    create(:project_membership, :member, user:, project:)
    obligation = create(:layered_verification_obligation, project:, external_revision: "a" * 40)
    allow(FeatureFlags).to receive(:enabled?).with(:layered_verification_add_on, project:).and_return(true)
    allow(AgentRuns::RunnerResolver).to receive(:call).and_return([ nil, "claude_code" ])

    run = described_class.call(
      project:,
      user:,
      obligation_ids: [ obligation.id ],
      target_revision: "a" * 40,
      budget_tokens: 12_000
    )

    expect(run).to have_attributes(goal: "layered_verification_audit", issue: nil, initiating_user: user)
    expect(run.external_metadata.fetch("layered_verification")).to include(
      "obligation_ids" => [ obligation.id ],
      "target_revision" => "a" * 40,
      "budget_tokens" => 12_000
    )
  end
end
