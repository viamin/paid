# frozen_string_literal: true

require "rails_helper"

RSpec.describe LayeredVerification::Audits::Request do
  let(:account) { create(:account) }
  let(:user) { create(:user, :member, account:) }
  let(:project) { create(:project, account:, created_by: user) }
  let!(:obligation) { create(:layered_verification_obligation, project:, external_revision: "abc123") }

  before { allow(FeatureFlags).to receive(:enabled?).with(:layered_verification_add_on, project:).and_return(true) }

  it "creates an issue-less audit run with resolved scope, provenance, revision, and budget" do # @spec LAYERED-VERIFY-010 @spec LAYERED-VERIFY-013
    run = described_class.call(project:, user:, obligation_ids: [ obligation.id ], budget: 12_000)

    expect(run).to have_attributes(goal: "layered_verification_audit", issue: nil, initiating_user: user, status: "queued")
    expect(run.external_metadata.fetch("layered_verification_audit")).to include(
      "obligation_ids" => [ obligation.id ], "target_revision" => "abc123", "budget" => 12_000
    )
    expect(ProcessRunQueueJob).to have_been_enqueued
  end

  it "rejects an empty scope and unauthorized users" do # @spec LAYERED-VERIFY-010
    expect { described_class.call(project:, user:, obligation_ids: [], budget: 12_000) }
      .to raise_error(ArgumentError, /at least one obligation/)

    viewer = create(:user, :viewer, account:)
    expect { described_class.call(project:, user: viewer, obligation_ids: [ obligation.id ], budget: 12_000) }
      .to raise_error(LayeredVerification::AuditAccess::UnauthorizedError)
  end
end
