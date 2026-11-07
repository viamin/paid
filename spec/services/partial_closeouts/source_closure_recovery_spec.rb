# frozen_string_literal: true

require "rails_helper"

RSpec.describe PartialCloseouts::SourceClosureRecovery do
  let(:run) { create(:agent_run, status: "running", branch_name: "paid/4886", result_commit_sha: "a" * 40) }

  # @spec PARTIAL-CLOSEOUT-044
  it "parks exhausted transient assessment work with the immutable pushed revision" do
    described_class.park!(agent_run: run, category: "timeout", attempts: 3)

    recovery = run.reload.reconciliation.fetch("source_closure_recovery")
    expect(run.status).to eq("waiting_recovery")
    expect(recovery).to include("failed_step" => "assess_source_closure", "branch_name" => "paid/4886",
      "commit_sha" => "a" * 40, "attempts" => 3, "failure_category" => "timeout")
    expect(Time.zone.parse(recovery.fetch("next_retry_at"))).to be > Time.current
  end

  # @spec PARTIAL-CLOSEOUT-045
  it "allows only one recovery claimant and never recreates the agent run" do
    described_class.park!(agent_run: run, category: "transport_error", attempts: 3)

    expect(described_class.claim!(agent_run: run)).to be(true)
    expect(described_class.claim!(agent_run: run.reload)).to be(false)
    expect(run.reload.id).to eq(run.id)
  end

  # @spec PARTIAL-CLOSEOUT-045
  it "releases only the matching workflow-start claim" do
    described_class.park!(agent_run: run, category: "transport_error", attempts: 3)
    described_class.claim!(agent_run: run)

    expect(described_class.release_claim!(agent_run: run, attempts: 2)).to be(false)
    expect(described_class.release_claim!(agent_run: run, attempts: 1)).to be(true)
    expect(run.reload.reconciliation.dig("source_closure_recovery", "claimed_at")).to be_nil
  end
end
