# frozen_string_literal: true

require "rails_helper"

RSpec.describe PartialCloseouts::Advance do
  let(:account) { create(:account) }
  let(:owner) { create(:user, account: account) }
  let(:project) { create(:project, account: account, created_by: owner, auto_pick_enabled: true) }
  let(:issue) { create(:issue, project: project, github_state: "open", paid_state: "in_progress") }
  let(:run) do
    create(:agent_run, :completed, project: project, issue: issue, goal: "create_pr",
      pull_request_number: 12, pull_request_url: "https://github.com/acme/alpha/pull/12", completed_at: 2.days.ago)
  end

  before do
    create(:issue, :pull_request, project: project, parent_issue: issue, github_number: 12,
      github_state: "closed", pr_review_phase: "merged")
  end

  # @spec PARTIAL-CLOSEOUT-024
  it "automatically schedules one fresh acceptance audit after stale gaps have shipped" do
    result = described_class.call(agent_run: run, assessment: { "gaps" => [] })

    expect(result.scheduled?).to be(true)
    expect(result.agent_run.trigger_type).to eq("automatic")
    expect(result.agent_run.auto_pick).to be(true)
    expect(result.agent_run.goal).to eq("analyze_issue")
    expect(result.agent_run.continuation_request.evidence["continuation_mode"]).to eq("acceptance_audit")
    expect(result.agent_run.continuation_request.reason).to include("report-only acceptance audit")
    expect(run.reload.reconciliation.dig("advance", "outcome")).to eq("scheduled")
  end

  # @spec PARTIAL-CLOSEOUT-024
  it "does not schedule an audit while focused implementation work remains" do
    result = described_class.call(agent_run: run, assessment: { "gaps" => [ { "criterion" => "dispatch" } ] })

    expect(result.scheduled?).to be(false)
    expect(issue.reload.agent_runs.where.not(id: run.id)).to be_empty
  end

  # @spec PARTIAL-CLOSEOUT-057
  it "queues one delegated implementation continuation for a current source-retained gap" do
    FeatureFlags.enable!(:automation_phases, project: project)
    FeatureFlags.enable!(:project_delegation, project: project)
    create(:project_delegation_posture, project: project, level: "bounded_delivery", selected_by: owner)
    assessment = { "source_revision" => PartialCloseouts::Assessment.source_revision_for(issue),
      "intent_revision" => PartialCloseouts::Assessment.intent_revision_for(issue), "gaps" => [
      { "criterion" => "dispatch", "kind" => "agent", "retain_on_source" => true, "body" => "Wire dispatch." }
    ] }

    first = described_class.call(agent_run: run, assessment: assessment)
    second = described_class.call(agent_run: run, assessment: assessment)

    expect(first.scheduled?).to be(true)
    expect(first.agent_run.goal).to eq("create_pr")
    expect(first.agent_run.continuation_request.evidence).to include("remaining_work" => hash_including("criterion" => "dispatch"))
    expect(first.agent_run.continuation_request.evidence).to include(
      "prior_closeout_evidence" => hash_including("agent_run_id" => run.id, "pull_request_number" => 12)
    )
    expect(first.agent_run.continuation_request.evidence.dig("technical_choice", "effective_policy")).to include("permitted" => true)
    expect(run.reload.reconciliation.dig("advance", "inbox_decision_avoided")).to be(true)
    expect(run.reconciliation.dig("advance", "completion_outcome")).to eq("continuation_queued")
    expect(second.code).to eq(:unchanged_gap)
    expect(IssueContinuationRequest.where(issue: issue).count).to eq(1)
  end

  # @spec PARTIAL-CLOSEOUT-057
  it "keeps a stale source or intent revision visible for one focused decision" do
    FeatureFlags.enable!(:automation_phases, project: project)
    FeatureFlags.enable!(:project_delegation, project: project)
    create(:project_delegation_posture, project: project, level: "bounded_delivery", selected_by: owner)
    assessment = { "source_revision" => PartialCloseouts::Assessment.source_revision_for(issue),
      "intent_revision" => PartialCloseouts::Assessment.intent_revision_for(issue), "gaps" => [
        { "criterion" => "dispatch", "kind" => "agent", "retain_on_source" => true, "body" => "Wire dispatch." }
      ] }
    issue.update!(title: "Updated acceptance intent")

    result = described_class.call(agent_run: run, assessment: assessment)

    expect(result.code).to eq(:human_decision_required)
    expect(IssueContinuationRequest.where(issue: issue)).to be_empty
    expect(run.reload.reconciliation.dig("advance", "inbox_decision_avoided")).to be(false)
  end

  # @spec PARTIAL-CLOSEOUT-057
  it "does not continue when the effective coding policy is disabled" do
    FeatureFlags.enable!(:automation_phases, project: project)
    FeatureFlags.enable!(:project_delegation, project: project)
    create(:project_delegation_posture, project: project, level: "bounded_delivery", selected_by: owner)
    project.update!(automation_phase_settings: { "phases" => { "coding" => false } })
    assessment = { "source_revision" => PartialCloseouts::Assessment.source_revision_for(issue),
      "intent_revision" => PartialCloseouts::Assessment.intent_revision_for(issue), "gaps" => [
        { "criterion" => "dispatch", "kind" => "agent", "retain_on_source" => true, "body" => "Wire dispatch." }
      ] }

    result = described_class.call(agent_run: run, assessment: assessment)

    expect(result.code).to eq(:human_decision_required)
    expect(IssueContinuationRequest.where(issue: issue)).to be_empty
  end

  # @spec PARTIAL-CLOSEOUT-057
  it "keeps a source-retained gap in Inbox when delegation is not explicitly enabled" do
    result = described_class.call(agent_run: run, assessment: { "gaps" => [
      { "criterion" => "dispatch", "kind" => "agent", "retain_on_source" => true }
    ] })

    expect(result.code).to eq(:human_decision_required)
    expect(IssueContinuationRequest.where(issue: issue)).to be_empty
  end

  # @spec PARTIAL-CLOSEOUT-024
  it "waits until the source run is terminal before requesting an audit" do
    run.update!(status: "running", completed_at: nil)

    result = described_class.call(agent_run: run, assessment: { "gaps" => [] })

    expect(result.code).to eq(:source_run_in_flight)
    expect(IssueContinuationRequest.where(issue: issue)).to be_empty
  end

  # @spec PARTIAL-CLOSEOUT-024
  it "respects disabled automation and leaves the issue for normal visibility" do
    project.update!(auto_pick_enabled: false)

    result = described_class.call(agent_run: run, assessment: { "gaps" => [] })

    expect(result.scheduled?).to be(false)
    expect(result.code).to eq(:automation_disabled)
    expect(run.reload.reconciliation.dig("advance", "outcome")).to eq("waiting")
    expect(IssueContinuationRequest.where(issue: issue)).to be_empty
  end

  # @spec PARTIAL-CLOSEOUT-024
  it "does not bypass an explicit hold" do
    issue.update_columns(paused: true)

    result = described_class.call(agent_run: run, assessment: { "gaps" => [] })

    expect(result.scheduled?).to be(false)
    expect(result.code).to eq(:operator_pause)
    expect(IssueContinuationRequest.where(issue: issue)).to be_empty
  end

  # @spec PARTIAL-CLOSEOUT-024
  it "is replay-safe when concurrent recovery sees an existing authorization" do
    first = described_class.call(agent_run: run, assessment: { "gaps" => [] })
    second = described_class.call(agent_run: run, assessment: { "gaps" => [] })

    expect(first.scheduled?).to be(true)
    expect(second.scheduled?).to be(true)
    expect(IssueContinuationRequest.where(issue: issue).count).to eq(1)
    expect(issue.agent_runs.where(goal: "analyze_issue").count).to eq(1)
  end
end
