# frozen_string_literal: true

require "rails_helper"

RSpec.describe PartialCloseouts::SourceClosureRecovery do
  let(:project) { create(:project, auto_pick_enabled: true) }
  let(:run) { create(:agent_run, project:, status: "running", branch_name: "paid/4886", result_commit_sha: "a" * 40) }

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

  # @spec PARTIAL-CLOSEOUT-061
  it "stops automatic recovery across repeated workflow epochs without resetting its lineage" do
    described_class.park!(agent_run: run, category: "timeout", attempts: 3)

    3.times do
      expect(described_class.claim!(agent_run: run.reload)).to be(true)
      described_class.park!(agent_run: run.reload, category: "timeout", attempts: 3)
    end

    expect(described_class.claim!(agent_run: run.reload)).to be(false)
    recovery = run.reload.reconciliation.fetch("source_closure_recovery")
    expect(recovery).to include("recovery_attempt" => 3, "automatic_recovery_attempt" => 3,
      "stop_reason" => "automatic_recovery_budget_exhausted", "commit_sha" => "a" * 40)
  end

  # @spec PARTIAL-CLOSEOUT-061
  it "records actual assessment requests separately from recovery claims" do
    described_class.park!(agent_run: run, category: "timeout", attempts: 3)
    described_class.claim!(agent_run: run)

    described_class.record_assessment_request!(agent_run: run)

    expect(run.reload.reconciliation.dig("source_closure_recovery", "assessment_request_count")).to eq(1)
    expect(run.reload.reconciliation.dig("source_closure_recovery", "recovery_attempt")).to eq(1)
  end

  # @spec PARTIAL-CLOSEOUT-061
  it "stops a legacy exhausted lineage without minting a claim or assessment request" do
    run.update!(reconciliation: { "source_closure_recovery" => { "recovery_attempt" => 40 } })

    described_class.park!(agent_run: run, category: "timeout", attempts: 3)

    expect(described_class.claim!(agent_run: run)).to be(false)
    recovery = run.reload.reconciliation.fetch("source_closure_recovery")
    expect(recovery).to include("recovery_attempt" => 40, "automatic_recovery_attempt" => 40,
      "stop_reason" => "automatic_recovery_budget_exhausted", "next_retry_at" => nil)
    expect(recovery).not_to have_key("assessment_request_count")
  end

  # @spec PARTIAL-CLOSEOUT-061
  it "stops automatic recovery when its current authorization, trust, pause, or budget is denied" do
    cases = {
      authorization: [ -> { run.project.update!(auto_pick_enabled: false) }, "automatic_recovery_authorization_withdrawn" ],
      trust: [ -> { run.project.update!(allowed_github_usernames: [ "another-user" ]) }, "automatic_recovery_source_untrusted" ],
      pause: [ -> { run.project.update!(scheduler_paused_at: Time.current) }, "automatic_recovery_paused" ],
      budget: [ -> { create(:cost_budget, :hard_stop, project: run.project, current_usage_cents: 100_000) }, "automatic_recovery_budget_exhausted" ]
    }

    cases.each do |kind, (deny, expected_reason)|
      run.update!(reconciliation: {})
      run.project.update!(auto_pick_enabled: true, allowed_github_usernames: [ "viamin" ], scheduler_paused_at: nil)
      run.project.cost_budgets.destroy_all
      deny.call
      described_class.park!(agent_run: run, category: "timeout", attempts: 3)

      expect(described_class.claim!(agent_run: run.reload)).to be(false), kind.to_s
      expect(run.reload.reconciliation.dig("source_closure_recovery", "stop_reason"))
        .to eq(expected_reason)
    end
  end

  # @spec PARTIAL-CLOSEOUT-060
  it "allows one explicit operator recovery without renewing automatic spending authority" do
    described_class.park!(agent_run: run, category: "timeout", attempts: 3)
    3.times do
      described_class.claim!(agent_run: run.reload)
      described_class.park!(agent_run: run.reload, category: "timeout", attempts: 3)
    end

    expect(described_class.claim!(agent_run: run.reload, operator_authorized: true)).to be(true)
    expect(described_class.claim!(agent_run: run.reload, operator_authorized: true)).to be(false)
    recovery = run.reload.reconciliation.fetch("source_closure_recovery")
    expect(recovery).to include("automatic_recovery_attempt" => 3, "operator_recovery_attempt" => 1,
      "recovery_attempt" => 4)
  end
end
