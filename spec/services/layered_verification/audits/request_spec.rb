# frozen_string_literal: true

require "rails_helper"

RSpec.describe LayeredVerification::Audits::Request do
  let(:user) { create(:user, :owner) }
  let(:project) { create(:project, account: user.account, created_by: user) }
  let(:obligation) { create(:layered_verification_obligation, project:) }

  before { FeatureFlags.enable!(:layered_verification_add_on, project:) }

  it "creates an issue-less audit run with the resolved request snapshot" do # @spec LAYERED-VERIFY-013
    run = described_class.call(user:, project:, obligation_ids: [ obligation.id ], sources: [ "docs/intent/payments.md" ],
      target_revision: "abc123", budget: { tokens: 1000 })

    expect(run).to have_attributes(goal: "layered_verification_audit", issue: nil, initiating_user: user)
    expect(run.external_metadata.dig("layered_verification_audit", "target_revision")).to eq("abc123")
  end

  it "requires an explicit scope" do # @spec LAYERED-VERIFY-013
    expect {
      described_class.call(user:, project:, obligation_ids: [], sources: [ "docs/intent/payments.md" ], target_revision: "abc123")
    }.to raise_error(described_class::ScopeRequiredError, /obligation/)
  end
end
