# frozen_string_literal: true

require "rails_helper"

RSpec.describe PartialCloseouts::ConfirmSync do
  let(:project) { create(:project) }
  let(:issue) { create(:issue, :in_progress, project:, github_state: "open", body: "expected") }
  let(:run) do
    create(:agent_run, :completed, project:, issue:, reconciliation: {
      "status" => "pending_sync",
      "assessment" => { "gaps" => [] },
      "sync_confirmation" => {
        "status" => "pending", "attempts" => 0, "max_attempts" => 3,
        "expected_body_digest" => Digest::SHA256.hexdigest("expected")
      }
    })
  end

  # @spec PARTIAL-CLOSEOUT-039
  it "confirms a matching body and restores the normal terminal status" do
    run
    described_class.call(project:, issue_id: issue.id)

    expect(run.reload.reconciliation).to include("status" => "reconciled")
    expect(run.reconciliation.dig("sync_confirmation", "status")).to eq("confirmed")
  end

  # @spec PARTIAL-CLOSEOUT-040
  it "bounds mismatches and records an explicit manual resolution" do
    run
    issue.update!(body: "different")
    run.update!(reconciliation: run.reconciliation.deep_merge(
      "sync_confirmation" => { "attempts" => 2 }
    ))

    described_class.call(project:, issue_id: issue.id)

    expect(run.reload.reconciliation).to include("status" => "retryable_failure")
    expect(run.reconciliation.dig("sync_confirmation")).to include(
      "status" => "exhausted", "resolution" => "manual_sync_review", "attempts" => 3
    )

    described_class.call(project:, issue_id: issue.id)
    expect(run.reload.reconciliation.dig("sync_confirmation", "attempts")).to eq(3)
  end
end
