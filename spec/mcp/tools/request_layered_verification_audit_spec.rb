# frozen_string_literal: true

require "rails_helper"

RSpec.describe Tools::RequestLayeredVerificationAudit do
  let(:account) { create(:account) }
  let(:user) { create(:user, account:) }
  let(:project) { create(:project, account:, created_by: user) }
  let(:session) { create(:chat_session, account:, project:, created_by: user) }

  before { allow(FeatureFlags).to receive(:enabled?).with(:layered_verification_add_on, project:).and_return(true) }

  # @spec LAYERED-VERIFY-014
  it "uses the same feature and authorization gate for chat advertisement and dispatch" do
    create(:layered_verification_obligation, project:, external_identity: "PAYMENTS-001")
    expect(described_class.available_for_chat?(user:, session:)).to be(true)

    result = described_class.new(user:, session:).call(project_id: project.id, scope: [ "PAYMENTS-001" ],
      source_references: [ "docs/intent/payments.md" ], target_revision: "abc123", budget: 1200, confirmed: true)

    expect(result).to include(status: "queued", scope: [ "PAYMENTS-001" ], budget: 1200)
  end
end
