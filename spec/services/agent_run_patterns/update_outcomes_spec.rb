# frozen_string_literal: true

require "rails_helper"

RSpec.describe AgentRunPatterns::UpdateOutcomes do
  let(:account) { create(:account) }
  let(:project) { create(:project, account: account) }

  # @spec RUN-OBSTACLE-005
  it "reports insufficient evidence until the post-correction exposure is comparable" do
    decision = create(
      :remediation_decision,
      account: account,
      status: "applied",
      applied_at: 1.hour.ago,
      pre_remediation_failure_count: 3,
      pre_remediation_exposure_count: 5,
      proposal_context: { "goal" => "enhance_issue", "window_hours" => 6 }
    )
    create_list(:agent_run, 3, :failed, project: project, goal: "enhance_issue", completed_at: 30.minutes.ago)

    described_class.call(account: account)

    expect(decision.reload).to have_attributes(
      post_remediation_failure_count: 3,
      post_remediation_exposure_count: 3,
      outcome: "insufficient_evidence"
    )
  end

  # @spec RUN-OBSTACLE-005
  it "re-evaluates insufficient evidence after comparable exposure accrues" do
    decision = create(
      :remediation_decision,
      account: account,
      status: "applied",
      applied_at: 1.hour.ago,
      pre_remediation_failure_count: 3,
      pre_remediation_exposure_count: 5,
      proposal_context: { "goal" => "enhance_issue", "window_hours" => 6 },
      outcome: "insufficient_evidence"
    )
    create_list(:agent_run, 2, :completed, project: project, goal: "enhance_issue", completed_at: 30.minutes.ago)

    described_class.call(account: account)

    create_list(:agent_run, 3, :completed, project: project, goal: "enhance_issue", completed_at: 15.minutes.ago)

    described_class.call(account: account)

    expect(decision.reload).to have_attributes(
      post_remediation_failure_count: 0,
      post_remediation_exposure_count: 5,
      outcome: "improved"
    )
  end

  # @spec RUN-OBSTACLE-005
  it "compares recurrence only after equivalent exposure and records an observed improvement" do
    decision = create(
      :remediation_decision,
      account: account,
      status: "applied",
      applied_at: 1.hour.ago,
      pre_remediation_failure_count: 3,
      pre_remediation_exposure_count: 5,
      proposal_context: { "goal" => "enhance_issue", "window_hours" => 6 }
    )
    create(:agent_run, :failed, project: project, goal: "enhance_issue", completed_at: 30.minutes.ago)
    create_list(:agent_run, 4, :completed, project: project, goal: "enhance_issue", completed_at: 30.minutes.ago)

    described_class.call(account: account)

    expect(decision.reload).to have_attributes(
      post_remediation_failure_count: 1,
      post_remediation_exposure_count: 5,
      outcome: "improved"
    )
  end

  # @spec RUN-OBSTACLE-005
  it "records an ineffective correction as unchanged once exposure is comparable" do
    decision = create(
      :remediation_decision,
      account: account,
      status: "applied",
      applied_at: 1.hour.ago,
      pre_remediation_failure_count: 3,
      pre_remediation_exposure_count: 5,
      proposal_context: { "goal" => "enhance_issue", "window_hours" => 6 }
    )
    create_list(:agent_run, 3, :failed, project: project, goal: "enhance_issue", completed_at: 30.minutes.ago)
    create_list(:agent_run, 2, :completed, project: project, goal: "enhance_issue", completed_at: 30.minutes.ago)

    described_class.call(account: account)

    expect(decision.reload.outcome).to eq("unchanged")
  end

  # @spec RUN-OBSTACLE-005
  it "excludes failures outside the proposal's post-remediation window" do
    decision = create(
      :remediation_decision,
      account: account,
      status: "applied",
      applied_at: 7.hours.ago,
      pre_remediation_failure_count: 1,
      pre_remediation_exposure_count: 2,
      proposal_context: { "goal" => "enhance_issue", "window_hours" => 6 }
    )
    create(:agent_run, :failed, project: project, goal: "enhance_issue", completed_at: 6.hours.ago)
    create(:agent_run, :completed, project: project, goal: "enhance_issue", completed_at: 5.hours.ago)
    create_list(:agent_run, 3, :failed, project: project, goal: "enhance_issue", completed_at: 30.minutes.ago)

    described_class.call(account: account)

    expect(decision.reload).to have_attributes(
      post_remediation_failure_count: 1,
      post_remediation_exposure_count: 2,
      outcome: "unchanged"
    )
  end

  # @spec RUN-OBSTACLE-005
  it "reports improved for a failure-streak proposal when the streak breaks immediately" do
    decision = create(
      :remediation_decision,
      account: account,
      status: "applied",
      applied_at: 1.hour.ago,
      pre_remediation_failure_count: 3,
      pre_remediation_exposure_count: 4,
      proposal_context: { "goal" => "enhance_issue", "pattern_type" => "failure_streak", "window_hours" => 6 }
    )
    create(:agent_run, :completed, project: project, goal: "enhance_issue", completed_at: 50.minutes.ago)
    create_list(:agent_run, 3, :failed, project: project, goal: "enhance_issue", completed_at: 10.minutes.ago)

    described_class.call(account: account)

    expect(decision.reload).to have_attributes(
      post_remediation_failure_count: 0,
      post_remediation_exposure_count: 4,
      outcome: "improved"
    )
  end

  # @spec RUN-OBSTACLE-005
  it "reports regressed for a failure-streak proposal only when failures resume immediately" do
    decision = create(
      :remediation_decision,
      account: account,
      status: "applied",
      applied_at: 1.hour.ago,
      pre_remediation_failure_count: 2,
      pre_remediation_exposure_count: 4,
      proposal_context: { "goal" => "enhance_issue", "pattern_type" => "failure_streak", "window_hours" => 6 }
    )
    create_list(:agent_run, 3, :failed, project: project, goal: "enhance_issue", completed_at: 50.minutes.ago)
    create(:agent_run, :completed, project: project, goal: "enhance_issue", completed_at: 10.minutes.ago)

    described_class.call(account: account)

    expect(decision.reload).to have_attributes(
      post_remediation_failure_count: 3,
      post_remediation_exposure_count: 4,
      outcome: "regressed"
    )
  end

  # @spec RUN-OBSTACLE-005
  it "counts only the diagnosed error pattern for error-cluster proposals" do
    decision = create_error_cluster_decision
    create_error_cluster_runs

    described_class.call(account: account)

    expect(decision.reload).to have_attributes(
      post_remediation_failure_count: 1,
      post_remediation_exposure_count: 4,
      outcome: "improved"
    )
  end

  # @spec RUN-OBSTACLE-005
  it "counts provider-exhaustion failures by their structured categories" do
    decision = create(
      :remediation_decision,
      account: account,
      status: "applied",
      applied_at: 1.hour.ago,
      pre_remediation_failure_count: 2,
      pre_remediation_exposure_count: 2,
      proposal_context: {
        "goal" => "analyze_issue",
        "pattern_type" => "error_cluster",
        "error_pattern" => "All issue-analysis providers exhausted: provider_auth, rate_limited",
        "window_hours" => 6
      }
    )
    create_list(:agent_run, 2, :completed, project: project, goal: "analyze_issue", completed_at: 30.minutes.ago)
    create_provider_exhaustion_run
    create_provider_exhaustion_run

    described_class.call(account: account)

    expect(decision.reload).to have_attributes(
      post_remediation_failure_count: 2,
      post_remediation_exposure_count: 4,
      outcome: "unchanged"
    )
  end

  # @spec RUN-OBSTACLE-005
  it "uses the detected fingerprint for applied decisions created before proposal context existed" do
    decision = create_legacy_applied_decision

    described_class.call(account: account)

    expect(decision.reload).to have_attributes(
      post_remediation_failure_count: 3,
      outcome: "unchanged"
    )
  end

  def create_error_cluster_decision
    create(
      :remediation_decision,
      account: account,
      status: "applied",
      applied_at: 1.hour.ago,
      pre_remediation_failure_count: 2,
      pre_remediation_exposure_count: 4,
      proposal_context: {
        "goal" => "enhance_issue",
        "pattern_type" => "error_cluster",
        "error_pattern" => "quota exhausted <N>",
        "window_hours" => 6
      }
    )
  end

  def create_error_cluster_runs
    create(:agent_run, :failed, project: project, goal: "enhance_issue", error_message: "quota exhausted 7", completed_at: 30.minutes.ago)
    create_list(:agent_run, 3, :failed, project: project, goal: "enhance_issue", error_message: "unrelated failure", completed_at: 30.minutes.ago)
  end

  def create_provider_exhaustion_run
    run = create(
      :agent_run,
      :failed,
      project: project,
      goal: "analyze_issue",
      error_message: "All issue-analysis providers exhausted: openai (provider_auth), anthropic (rate_limited)",
      completed_at: 30.minutes.ago
    )
    create(:agent_run_log, :system, agent_run: run,
      metadata: { type: AgentRunLog::PROVIDER_FAILURE_TYPE, failure_category: "provider_auth" })
    create(:agent_run_log, :system, agent_run: run,
      metadata: { type: AgentRunLog::PROVIDER_FAILURE_TYPE, failure_category: "rate_limited" })
  end

  def create_legacy_applied_decision
    create_list(:agent_run, 3, :failed, project: project, goal: "enhance_issue", error_message: "GitHub API quota exhausted", completed_at: 30.minutes.ago)
    create(
      :remediation_decision,
      account: account,
      fingerprint: legacy_fingerprint,
      status: "applied",
      applied_at: 1.hour.ago,
      pre_remediation_failure_count: 3,
      proposal_context: {}
    )
  end

  def legacy_fingerprint
    AgentRunPatterns::Detect.call(account: account).find { |pattern| pattern.type == :error_cluster }.details[:fingerprint]
  end
end
