# frozen_string_literal: true

require "rails_helper"

RSpec.describe LayeredVerification::Audits::Request do
  let(:account) { create(:account) }
  let(:user) { create(:user, account:) }
  let(:project) { create(:project, account:, created_by: user) }

  before { allow(FeatureFlags).to receive(:enabled?).with(:layered_verification_add_on, project:).and_return(true) }

  # @spec LAYERED-VERIFY-010 @spec LAYERED-VERIFY-013
  it "creates an issue-less audit with an immutable dispatch snapshot" do
    create(:layered_verification_obligation, project:, external_identity: "PAYMENTS-001")
    result = described_class.call(project:, actor: user, scope: [ "PAYMENTS-001" ],
      source_references: [ "docs/intent/payments.md" ], target_revision: "abc123", budget: 1200)

    expect(result.agent_run).to have_attributes(goal: "layered_verification_audit", issue_id: nil, initiating_user: user)
    expect(result.agent_run.reconciliation.dig("layered_verification_audit")).to include(
      "scope" => [ "PAYMENTS-001" ], "target_revision" => "abc123", "budget" => 1200, "trigger" => "manual"
    )
  end
end
