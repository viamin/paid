# frozen_string_literal: true

require "rails_helper"

RSpec.describe LayeredVerification::Audits::Request do
  # @spec LAYERED-VERIFY-010 @spec LAYERED-VERIFY-013 @spec LAYERED-VERIFY-014
  it "creates an issue-less, bounded audit run with resolved dispatch context" do
    project = create(:project)
    user = create(:user, :member, account: project.account)
    obligation = create(:layered_verification_obligation, project: project)
    allow(FeatureFlags).to receive(:enabled?).with(:layered_verification_add_on, project:).and_return(true)

    run = described_class.call(
      user: user, project: project, obligation_ids: [ obligation.id ],
      source_references: [ "docs/intent/payments.md" ], target_revision: "abc123", budget_tokens: 2_000
    )

    expect(run).to have_attributes(goal: "layered_verification_audit", issue_id: nil, initiating_user: user)
    expect(run.external_metadata).to include(
      "obligation_ids" => [ obligation.id ], "source_references" => [ "docs/intent/payments.md" ],
      "target_revision" => "abc123", "budget_tokens" => 2_000
    )
  end
end
