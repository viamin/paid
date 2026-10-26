# frozen_string_literal: true

require "rails_helper"

RSpec.describe Tools::RequestLayeredVerificationAudit do
  # @spec LAYERED-VERIFY-010 @spec LAYERED-VERIFY-013 @spec LAYERED-VERIFY-014
  it "uses the shared audit request path and returns the resolved scope" do
    account = create(:account)
    user = create(:user, :member, account: account)
    project = create(:project, account: account)
    obligation = create(:layered_verification_obligation, project: project)
    session = create(:chat_session, account: account, created_by: user)
    allow(FeatureFlags).to receive(:enabled?).with(:layered_verification_add_on, project:).and_return(true)

    tool = described_class.new(user:, session:)
    preview = tool.call(project_id: project.id, obligation_ids: [ obligation.id ],
      source_references: [ "docs/intent/payments.md" ], target_revision: "abc123", budget_tokens: 2_000)
    result = tool.resolve_confirmation(decision: :approve, pending_result: preview)

    expect(result).to include(status: "queued", goal: "layered_verification_audit")
    expect(result[:resolved_scope]).to include("target_revision" => "abc123")
  end

  # @spec LAYERED-VERIFY-012 @spec LAYERED-VERIFY-014
  it "does not advertise the tool while the default-off flag is disabled" do
    account = create(:account)
    user = create(:user, :member, account: account)

    expect(described_class.available_to?(user:)).to be(false)
  end
end
