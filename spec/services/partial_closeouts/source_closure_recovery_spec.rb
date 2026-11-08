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

  # @spec PARTIAL-CLOSEOUT-044
  it "retains the database-enforced work slot while parked" do
    described_class.park!(agent_run: run, category: "timeout", attempts: 3)

    expect do
      create(:agent_run, project: run.project, issue: run.issue, goal: run.goal, status: "queued")
    end.to raise_error(ActiveRecord::RecordNotUnique)

    pr_run = create(:agent_run, project: run.project, status: "running", source_pull_request_number: 91)
    described_class.park!(agent_run: pr_run, category: "timeout", attempts: 3)

    expect do
      create(:agent_run, project: pr_run.project, issue: nil, goal: pr_run.goal,
        source_pull_request_number: pr_run.source_pull_request_number, status: "queued")
    end.to raise_error(ActiveRecord::RecordNotUnique)
  end

  # @spec PARTIAL-CLOSEOUT-045
  it "allows only one recovery claimant and never recreates the agent run" do
    described_class.park!(agent_run: run, category: "transport_error", attempts: 3)

    expect(described_class.claim!(agent_run: run)).to be(true)
    expect(described_class.claim!(agent_run: run.reload)).to be(false)
    expect(run.reload.id).to eq(run.id)
  end

  # @spec PARTIAL-CLOSEOUT-045
  it "reclaims a recovery claim after its bounded lease expires" do
    described_class.park!(agent_run: run, category: "transport_error", attempts: 3)
    described_class.claim!(agent_run: run, now: 11.minutes.ago)

    expect(described_class.claim!(agent_run: run.reload)).to be(true)
    expect(run.reload.reconciliation.dig("source_closure_recovery", "recovery_attempt")).to eq(2)
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
