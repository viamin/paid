# frozen_string_literal: true

require "rails_helper"

RSpec.describe LayeredVerification::Audits::Request do
  let(:account) { create(:account, default_max_tokens_per_run: 42_000) }
  let(:user) { create(:user, :member, account:) }
  let(:project) { create(:project, account:, created_by: user) }

  before do
    allow(FeatureFlags).to receive(:enabled?).with(:layered_verification_add_on, project:).and_return(true)
  end

  # @spec LAYERED-VERIFY-010 @spec LAYERED-VERIFY-013 @spec LAYERED-VERIFY-020
  it "creates an issue-less audit run with resolved scope, source, revision, budget, and initiator" do
    obligation = create(:layered_verification_obligation, project:, external_revision: "abc123")

    run = described_class.call(project:, user:, target_revision: "abc123")

    expect(run).to have_attributes(goal: "layered_verification_audit", issue: nil, initiating_user: user)
    expect(run.external_metadata.fetch("layered_verification_audit")).to include(
      "obligation_ids" => [ obligation.id ],
      "sources" => [ obligation.external_identity ],
      "target_revision" => "abc123",
      "token_budget" => 42_000,
      "trigger" => "manual"
    )
  end

  # @spec LAYERED-VERIFY-010 @spec LAYERED-VERIFY-012
  it "refuses an audit when its rollout gate is disabled" do
    allow(FeatureFlags).to receive(:enabled?).with(:layered_verification_add_on, project:).and_return(false)

    expect { described_class.call(project:, user:) }
      .to raise_error(LayeredVerification::AuditAccess::FeatureDisabledError)
  end
end
