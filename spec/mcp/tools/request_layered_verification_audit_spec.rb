# frozen_string_literal: true

require "rails_helper"

RSpec.describe Tools::RequestLayeredVerificationAudit do
  let(:account) { create(:account) }
  let(:user) { create(:user, :member, account:) }
  let(:project) { create(:project, account:) }
  let(:session) { create(:chat_session, account:, created_by: user, project:) }

  before do
    allow(FeatureFlags).to receive(:enabled?).with(:layered_verification_add_on, project:).and_return(true)
    allow(AgentRuns::RunnerResolver).to receive(:call).and_return([ nil, "codex" ])
  end

  # @spec LAYERED-VERIFY-013 @spec LAYERED-VERIFY-014
  it "creates an issue-less, bounded audit run through the shared tool" do
    result = described_class.new(user:, session:).call(
      project_id: project.id, scope: "PAYMENTS-001", source_references: [ "docs/payments.md:12" ],
      target_revision: "abc123", budget: 2_000
    )

    run = AgentRun.find(result.fetch(:id))
    expect(run).to have_attributes(goal: "layered_verification_audit", issue_id: nil, initiating_user: user)
    expect(run.external_metadata).to include("scope" => "PAYMENTS-001", "target_revision" => "abc123", "budget" => 2_000)
  end
end
