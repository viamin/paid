# frozen_string_literal: true

require "rails_helper"

RSpec.describe LayeredVerification::Audits::Request do
  # @spec LAYERED-VERIFY-010 @spec LAYERED-VERIFY-013
  it "creates an issue-less, bounded audit run with its resolved provenance" do
    project = create(:project)
    obligation = create(:layered_verification_obligation, project:)
    user = project.created_by
    create(:account_membership, account: project.account, user:, role: :member)
    allow(FeatureFlags).to receive(:enabled?).with(:layered_verification_add_on, project:).and_return(true)

    result = request(project:, actor: user, obligation_ids: [ obligation.id ])

    run = result.run
    expect(run).to have_attributes(goal: "layered_verification_audit", issue_id: nil, initiating_user: user)
    expect(run.external_metadata).to include(
      "audit_scope" => [ obligation.external_identity ],
      "audit_sources" => [ "docs/intent/payments/specs.md#PAYMENTS-001" ],
      "audit_target_revision" => "abc123",
      "audit_budget" => { "max_tokens" => 2_000 },
      "audit_trigger" => "manual"
    )
  end

  # @spec LAYERED-VERIFY-021
  it "rejects an unbounded audit before it can dispatch" do
    project = create(:project)
    user = project.created_by
    create(:account_membership, account: project.account, user:, role: :member)
    allow(FeatureFlags).to receive(:enabled?).with(:layered_verification_add_on, project:).and_return(true)

    expect {
      request(project:, actor: user, obligation_ids: [], sources: [], budget: {})
    }.to raise_error(ArgumentError, /scope, source, target revision, and budget/)
  end

  def request(project:, actor:, obligation_ids:, sources: [ "docs/intent/payments/specs.md#PAYMENTS-001" ], budget: { "max_tokens" => 2_000 })
    described_class.call(project:, actor:, obligation_ids:, sources:, target_revision: "abc123", budget:)
  end
end
