# frozen_string_literal: true

require "rails_helper"

RSpec.describe Automation::Strategies::AutoContinue, :no_db do
  before do
    stub_const("AutoContinueNoDbProject", Class.new)
    stub_const("AutoContinueNoDbIssue", Struct.new(:project, keyword_init: true))
  end

  let(:strategy) { described_class.new }
  let(:project) { AutoContinueNoDbProject.new }
  let(:pull_request) { AutoContinueNoDbIssue.new(project: project) }
  let(:selected_strategy) { instance_double(Automation::Strategies::AutoReview) }
  let(:lifecycle) do
    {
      issue_id: 10,
      pr_number: 42,
      phase: "ready",
      active_run_exists: false,
      operational_failure_breaker: false,
      failure_streak_limit_reached: true,
      escalation_dismissed: false,
      owner_reviewer_login: "alice",
      escalation_reason: "Automatic PR failure streak reached",
      consecutive_unsuccessful_automatic_runs: 3,
      consecutive_operational_failures: 0,
      last_meaningful_progress_at: nil,
      draft: false
    }
  end
  let(:scan) do
    {
      issue_id: 10,
      pr_number: 42,
      phase: "ready",
      current_review_goal_retry_count: 1,
      triggers: [ { type: "review_goal_retry" } ]
    }
  end

  def decision_types(result)
    result.to_h[:decisions].map { |decision| decision[:type] }
  end

  def followup_scan
    {
      issue_id: 10,
      pr_number: 42,
      phase: "ready",
      current_followup_count: 1,
      labels_to_remove: [],
      triggers: [ { type: "ci_failure", details: "test-suite" } ]
    }
  end

  def auto_resolve_result
    instance_double(
      Coordination::EscalationService::Result,
      escalate?: false,
      auto_resolve?: true
    )
  end

  it "delegates to AutoReview instead of escalating when a review-goal retry is pending" do
    context = Automation::Context.build(record: pull_request, project: project, metadata: { lifecycle:, scan: })

    allow(Automation::Strategies::Select).to receive(:call)
      .with(strategy_type: :auto_review, project: project)
      .and_return(selected_strategy)
    allow(selected_strategy).to receive(:evaluate).and_return(
      Automation::Result.new(decisions: [
        Automation::Decision.queue_review_run(issue_id: 10, source_pull_request_number: 42, focus: "general"),
        Automation::Decision.record_review_goal_retry(issue_id: 10, expected_review_goal_retry_count: 1)
      ])
    )
    allow(Coordination::EscalationService).to receive(:call)

    result = strategy.evaluate(context)

    expect(decision_types(result)).to eq([ "queue_review_run", "record_review_goal_retry" ])
    expect(Coordination::EscalationService).not_to have_received(:call)
  end

  it "continues into AutoReview when escalation service decides auto_resolve" do
    context = Automation::Context.build(record: pull_request, project: project, metadata: { lifecycle:, scan: followup_scan })

    allow(Coordination::EscalationService).to receive(:call)
      .with(project: project, issue: pull_request, signals: kind_of(Automation::Strategies::AutoContinue::Signals))
      .and_return(auto_resolve_result)
    allow(Automation::Strategies::Select).to receive(:call)
      .with(strategy_type: :auto_review, project: project)
      .and_return(selected_strategy)
    allow(selected_strategy).to receive(:evaluate).and_return(
      Automation::Result.new(decisions: [
        Automation::Decision.queue_create_pr_run(issue_id: 10, source_pull_request_number: 42, focus: "ci_fix"),
        Automation::Decision.record_pr_followup(issue_id: 10, labels_to_remove: [], expected_followup_count: 1)
      ])
    )

    result = strategy.evaluate(context)

    expect(decision_types(result)).to eq([ "queue_create_pr_run", "record_pr_followup" ])
  end

  it "dismisses escalation before evaluating operational failure breakers" do
    context = Automation::Context.build(
      record: pull_request,
      project: project,
      metadata: {
        lifecycle: lifecycle.merge(
          phase: "escalated",
          operational_failure_breaker: true,
          escalation_dismissed: true
        )
      }
    )

    allow(Coordination::EscalationService).to receive(:call)

    result = strategy.evaluate(context)

    expect(decision_types(result)).to eq([ "dismiss_escalation" ])
    expect(Coordination::EscalationService).not_to have_received(:call)
  end
end
