# frozen_string_literal: true

require "rails_helper"

RSpec.describe LayeredVerification::Audits::Request do
  describe ".call" do
    # @spec LAYERED-VERIFY-010 @spec LAYERED-VERIFY-013 @spec LAYERED-VERIFY-021
    it "creates an issue-less, bounded audit run with its resolved dispatch context" do
      project = create(:project)
      user = create(:user, :member, account: project.account)
      obligation = create(:layered_verification_obligation, project:, external_revision: "intent-sha")
      allow(FeatureFlags).to receive(:enabled?).with(:layered_verification_add_on, project:).and_return(true)
      allow(AgentRuns::RunnerResolver).to receive(:call).and_return([ nil, "claude_code" ])
      allow(ProcessRunQueueJob).to receive(:perform_later)

      run = described_class.call(
        user:,
        project:,
        obligation_ids: [ obligation.id ],
        source_references: [ "docs/intent/orders.md#refunds" ],
        target_revision: "code-sha",
        budget_tokens: 12_000
      )

      expect(run).to have_attributes(project:, issue: nil, initiating_user: user, goal: "layered_verification_audit", base_commit_sha: "code-sha", status: "queued")
      expect(dispatch_context(run)).to include("obligation_ids" => [ obligation.id ], "source_references" => [ "docs/intent/orders.md#refunds" ], "target_revision" => "code-sha", "budget_tokens" => 12_000)
      expect(ProcessRunQueueJob).to have_received(:perform_later)
    end

    it "refuses an empty scope and does not dispatch" do
      project = create(:project)
      user = create(:user, :member, account: project.account)
      allow(FeatureFlags).to receive(:enabled?).with(:layered_verification_add_on, project:).and_return(true)

      expect {
        described_class.call(user:, project:, obligation_ids: [], source_references: [ "source" ], target_revision: "sha", budget_tokens: 100)
      }.to raise_error(ArgumentError, "at least one obligation is required")
    end
  end

  def dispatch_context(run)
    run.external_metadata.fetch("layered_verification_audit")
  end
end
