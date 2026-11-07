# frozen_string_literal: true

require "rails_helper"

RSpec.describe Workflows::SourceClosureRecoveryWorkflow do
  let(:workflow) { described_class.new }
  let(:input) do
    { agent_run_id: 42, project_id: 7, recovery_attempt: 1, goal: "create_feature", commit_sha: "a" * 40 }
  end
  let(:post_closeout_activities) do
    [
      Activities::ReconcilePartialCloseoutActivity,
      Activities::AdvancePartialCloseoutActivity,
      Activities::UpdateIssueWithPrActivity,
      Activities::RequestReviewActivity,
      Activities::CaptureScreenshotsActivity,
      Activities::DraftDecisionRecordActivity,
      Activities::ChainLidPlanningActivity
    ]
  end

  before do
    allow(Temporalio::Workflow).to receive(:logger).and_return(Rails.logger)
    allow(Temporalio::Workflow).to receive(:patched).with("source-closure-recovery-post-pr-v1").and_return(true)
    allow(Temporalio::Workflow).to receive(:patched).with("source-closure-recovery-pinned-revision-v1").and_return(true)
  end

  def activity_error(cause, retry_state: Temporalio::Error::RetryState::NON_RETRYABLE_FAILURE)
    begin
      begin
        raise cause
      rescue
        raise Temporalio::Error::ActivityError.new(
          "activity failed", scheduled_event_id: 1, started_event_id: 2, identity: "worker-1",
          activity_type: "AssessSourceClosure", activity_id: "assessment-1", retry_state: retry_state
        )
      end
    rescue => error
      error
    end
  end

  # @spec PARTIAL-CLOSEOUT-045
  it "continues through issue reconciliation and review publication after creating the PR" do
    calls = []
    allow(workflow).to receive(:run_activity) do |activity, _input, **_options|
      calls << activity
      case activity.name
      when "Activities::CreatePullRequestActivity"
        { pull_request_url: "https://github.com/o/r/pull/9", pull_request_number: 9 }
      when "Activities::ReconcilePartialCloseoutActivity"
        { gaps_remain: false }
      else
        {}
      end
    end
    allow(workflow).to receive(:run_cleanup_activity)

    expect(workflow.execute(input)).to include(recovered: true)
    expect(calls).to include(*post_closeout_activities)
    expect(workflow).to have_received(:run_activity).with(
      Activities::CreatePullRequestActivity,
      { agent_run_id: 42, expected_head_sha: "a" * 40 },
      timeout: 120
    )
  end

  # @spec PARTIAL-CLOSEOUT-045
  it "returns a force-pushed branch to visible recovery without publishing a PR" do
    allow(workflow).to receive(:run_activity) do |activity, _input, **_options|
      case activity.name
      when "Activities::CreatePullRequestActivity"
        { revision_mismatch: true }
      else
        {}
      end
    end
    allow(workflow).to receive(:run_cleanup_activity)

    expect(workflow.execute(input)).to include(waiting: true)
    expect(workflow).to have_received(:run_activity).with(
      Activities::ParkSourceClosureRecoveryActivity,
      { agent_run_id: 42, category: "branch_mismatch", attempts: 3, auto_retry: false },
      timeout: 30
    )
    expect(workflow).not_to have_received(:run_activity).with(Activities::ReconcilePartialCloseoutActivity, any_args)
  end

  # @spec PARTIAL-CLOSEOUT-045
  it "marks the run failed when recovery fails outside assessment" do
    allow(workflow).to receive(:run_activity) do |activity, _input, **_options|
      raise "provision failed" if activity == Activities::ProvisionContainerActivity
    end
    allow(workflow).to receive(:run_cleanup_activity)

    expect { workflow.execute(input) }.to raise_error("provision failed")
    expect(workflow).not_to have_received(:run_activity).with(Activities::ParkSourceClosureRecoveryActivity, any_args)
    expect(workflow).to have_received(:run_cleanup_activity).with(
      Activities::MarkAgentRunFailedActivity,
      { agent_run_id: 42, error: "provision failed", failure_type: "RuntimeError" }, timeout: 30
    )
  end

  # @spec PARTIAL-CLOSEOUT-044 PARTIAL-CLOSEOUT-045
  it "parks an assessment whose Temporal activity retries time out" do
    timeout = Temporalio::Error::TimeoutError.new(
      "start to close timeout", type: Temporalio::Error::TimeoutError::TimeoutType::START_TO_CLOSE,
      last_heartbeat_details: []
    )
    allow(workflow).to receive(:run_activity) do |activity, _input, **_options|
      raise activity_error(timeout, retry_state: Temporalio::Error::RetryState::TIMEOUT) if activity == Activities::AssessSourceClosureActivity

      {}
    end
    allow(workflow).to receive(:run_cleanup_activity)

    expect(workflow.execute(input)).to include(waiting: true)
    expect(workflow).to have_received(:run_activity).with(
      Activities::ParkSourceClosureRecoveryActivity,
      { agent_run_id: 42, category: "timeout", attempts: 3 }, timeout: 30
    )
  end

  # @spec PARTIAL-CLOSEOUT-045
  it "terminally fails a non-recoverable assessment without leaving the run waiting" do
    authentication_error = Temporalio::Error::ApplicationError.new(
      "credentials unavailable", { "category" => "authentication_unavailable" },
      type: "SourceClosureAssessmentFailure", non_retryable: true
    )
    allow(workflow).to receive(:run_activity) do |activity, _input, **_options|
      raise activity_error(authentication_error) if activity == Activities::AssessSourceClosureActivity

      {}
    end
    allow(workflow).to receive(:run_cleanup_activity)

    expect { workflow.execute(input) }.to raise_error(Temporalio::Error::ActivityError)
    expect(workflow).to have_received(:run_cleanup_activity).with(
      Activities::MarkAgentRunFailedActivity,
      { agent_run_id: 42, error: "credentials unavailable", failure_type: "SourceClosureAssessmentFailure" }, timeout: 30
    )
  end
end
