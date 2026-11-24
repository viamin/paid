# frozen_string_literal: true

require "rails_helper"

RSpec.describe Project do
  # @spec PR-ESCALATION-028 PR-ESCALATION-029
  let(:project) { create(:project, max_pr_followup_runs: 8, max_pr_auto_continue_tokens: 50_000, quality_gate_settings: { "enabled" => false }) }
  let(:scanner) { Activities::ScanPaidPrsActivity.new }
  let(:pull_request) { create(:issue, :pull_request, project: project, github_number: 42, pr_review_phase: "ready", pr_followup_count: 12) }

  it "rejects malformed or timezone-free deadlines instead of silently clearing the suspension" do
    [ "tomorrow", "2026-11-30T18:00:00", "2026-11-31T18:00:00Z", "9999999-01-01T00:00:00Z" ].each do |value|
      project.pr_escalation_limits_suspended_until = value
      expect(project).not_to be_valid
      expect(project.errors[:pr_escalation_limits_suspended_until]).not_to be_empty
    end
  end

  # @spec PR-ESCALATION-031
  it "rejects non-timestamp JSON values before saving or evaluating the policy" do
    [ 123, false, [] ].each do |value|
      project.pr_escalation_limits_suspended_until = value
      expect(project).not_to be_valid
      expect(project.errors[:pr_escalation_limits_suspended_until]).not_to be_empty
    end
  end

  it "preserves the instant of a valid deadline with a non-UTC offset" do
    project.update!(pr_escalation_limits_suspended_until: "2026-11-30T21:44:53+03:00")

    expect(project.reload.pr_escalation_limits_suspended_until.utc.iso8601).to eq("2026-11-30T18:44:53Z")
  end

  it "allows unrelated edits after loading a stored deadline" do
    project.update!(pr_escalation_limits_suspended_until: 1.week.from_now)
    expect(project.reload.update(name: "New name")).to be(true)
  end

  it "suspends both scanner limits without changing counters or configured caps" do
    project.update!(pr_escalation_limits_suspended_until: 1.week.from_now)

    expect(scanner.send(:total_followup_limit_reached?, project, pull_request)).to be(false)
    expect(scanner.send(:pr_failure_limit, project, pull_request)).to eq(0)
    expect(scanner.send(:pr_auto_continue_token_limit_breach, project, pull_request,
      budget: { used: 60_000, limit: 50_000 })).to be_nil
    expect(pull_request.reload.pr_followup_count).to eq(12)
    expect(project.reload.max_pr_auto_continue_tokens).to eq(50_000)
  end

  it "enforces both limits at the exact expiry instant" do
    deadline = 1.week.from_now.change(usec: 0)
    project.update!(pr_escalation_limits_suspended_until: deadline)

    travel_to(deadline) do
      expect(scanner.send(:total_followup_limit_reached?, project, pull_request)).to be(true)
      expect(scanner.send(:pr_failure_limit, project, pull_request)).to eq(8)
      expect(scanner.send(:pr_auto_continue_token_limit_breach, project, pull_request,
        budget: { used: 60_000, limit: 50_000 })).to include(used: 60_000)
    end
  end

  it "keeps draft limits active and does not suspend another project" do
    project.update!(pr_escalation_limits_suspended_until: 1.week.from_now)
    pull_request.update!(pr_review_phase: "draft")

    expect(scanner.send(:pr_failure_limit, project, pull_request)).to eq(project.max_draft_review_rounds)
    expect(create(:project).pr_escalation_limits_suspended?).to be(false)
    project.update!(pr_escalation_limits_suspended_until: nil)
    expect(project.pr_escalation_limits_suspended?).to be(false)
  end

  it "applies the suspension at execution and resumes enforcement against retained token usage" do
    pull_request
    create(:agent_run, project: project, issue: pull_request, source_pull_request_number: 42,
      trigger_type: "automatic", tokens_input: 60_000, status: "completed")
    deadline = 1.week.from_now.change(usec: 0)
    project.update!(pr_escalation_limits_suspended_until: deadline)
    input = { project_id: project.id, issue_id: pull_request.id, source_pull_request_number: 42 }

    expect(Activities::CheckQualityGateActivity.new.execute(input)).to include(allowed: true)
    travel_to(deadline) do
      expect(Activities::CheckQualityGateActivity.new.execute(input)).to include(
        allowed: false, reason: "pr_auto_continue_token_limit_exceeded")
    end
    expect(AgentRun.pr_auto_continue_tokens_used(project: project, pr_number: 42, issue: pull_request)).to eq(60_000)
  end
end
