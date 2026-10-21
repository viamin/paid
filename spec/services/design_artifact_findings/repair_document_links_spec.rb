# frozen_string_literal: true

require "rails_helper"

RSpec.describe DesignArtifactFindings::RepairDocumentLinks do
  let(:account) { create(:account) }
  let(:user) { create(:user, account:) }
  let(:project) { create(:project, account:, created_by: user) }
  let(:finding) { create(:design_artifact_finding, account:, project:, state: "stale_metadata") }
  let(:runner) { create(:runner, user:, runner_key: "codex") }

  # @spec OPERATOR-INBOX-018 DESIGN-RECONCILIATION-001
  it "queues one focused design-repair run and reuses it for a retry" do
    runner
    allow(ProcessRunQueueJob).to receive(:perform_later)

    first = described_class.call(finding:, user:, revision: finding.revision)
    second = described_class.call(finding:, user:, revision: finding.revision)

    expect(first).to eq(second)
    expect(first).to have_attributes(goal: "create_pr", status: "queued", issue: nil)
    expect(first.custom_prompt).to include(finding.artifact_path, finding.revision)
    expect(finding.reload).to have_attributes(status: "assigned", resolution_actor: user)
    expect(ProcessRunQueueJob).to have_received(:perform_later).once
  end
end
