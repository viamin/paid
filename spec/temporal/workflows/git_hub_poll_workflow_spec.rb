# frozen_string_literal: true

require "rails_helper"

RSpec.describe Workflows::GitHubPollWorkflow do
  let(:workflow) { described_class.new }

  before do
    allow(workflow).to receive(:quality_gate_allows_run?).and_return(true)
  end

  describe "#execute" do
    it "is defined as a Temporal workflow" do
      expect(described_class).to be < Workflows::BaseWorkflow
    end

    it "inherits from BaseWorkflow" do
      expect(described_class.superclass).to eq(Workflows::BaseWorkflow)
    end
  end

  describe "MAX_ITERATIONS" do
    it "is set to 100" do
      expect(described_class::MAX_ITERATIONS).to eq(100)
    end
  end

  describe "request_sync signal" do
    it "defines a request_sync signal handler" do
      info = described_class._workflow_definition
      expect(info.signals).to include("request_sync")
    end

    it "sets @sync_requested and calls cancel proc" do
      workflow = described_class.new
      cancel_called = false
      workflow.instance_variable_set(:@sleep_cancel_proc, proc { |**| cancel_called = true })

      workflow.request_sync

      expect(workflow.instance_variable_get(:@sync_requested)).to be true
      expect(cancel_called).to be true
    end

    it "tolerates nil cancel proc" do
      workflow = described_class.new
      workflow.instance_variable_set(:@sleep_cancel_proc, nil)

      expect { workflow.request_sync }.not_to raise_error
      expect(workflow.instance_variable_get(:@sync_requested)).to be true
    end
  end

  describe "ScanPaidPrsActivity patch guard" do
    let(:workflow) { described_class.new }

    before do
      allow(workflow).to receive(:run_activity).and_return({ prs_to_trigger: [] })
    end

    it "runs ScanPaidPrsActivity when patched returns true" do
      allow(Temporalio::Workflow).to receive(:patched).with("add-scan-paid-prs-v1").and_return(true)

      workflow.send(:maybe_scan_paid_prs, 1)

      expect(workflow).to have_received(:run_activity)
        .with(Activities::ScanPaidPrsActivity, { project_id: 1 }, timeout: 120)
    end

    it "skips ScanPaidPrsActivity when patched returns false" do
      allow(Temporalio::Workflow).to receive(:patched).with("add-scan-paid-prs-v1").and_return(false)

      workflow.send(:maybe_scan_paid_prs, 1)

      expect(workflow).not_to have_received(:run_activity)
        .with(Activities::ScanPaidPrsActivity, anything, timeout: anything)
    end
  end

  describe "notification rule evaluation" do
    let(:workflow) { described_class.new }

    before do
      allow(workflow).to receive(:run_activity)
      allow(Temporalio::Workflow).to receive(:patched).with("notification-rules-v1").and_return(true)
    end

    it "runs EvaluateNotificationRulesActivity with fetched issue ids and PR scan context" do
      workflow.send(:run_notification_rules, 1,
        issue_ids: [ 10, 11 ],
        pr_scan_result: {
          pr_issue_ids: [ 11 ],
          pending_review_states: [ { issue_id: 11, pending_review: true, requested_bot: "copilot", pr_phase: "draft" } ]
        })

      expect(workflow).to have_received(:run_activity).with(
        Activities::EvaluateNotificationRulesActivity,
        {
          project_id: 1,
          issue_ids: [ 10, 11 ],
          pr_issue_ids: [ 11 ],
          pending_review_states: [ { issue_id: 11, pending_review: true, requested_bot: "copilot", pr_phase: "draft" } ]
        },
        timeout: 60
      )
    end
  end

  describe "rate limit budget coordination" do
    let(:workflow) { described_class.new }

    before do
      allow(Temporalio::Workflow).to receive(:patched).and_return(true)
      allow(workflow).to receive(:run_activity).and_return({})
    end

    it "skips non-critical activities when rate limit is low" do
      allow(workflow).to receive(:run_activity)
        .with(Activities::CheckRateLimitActivity, anything, timeout: anything)
        .and_return({ rate_limit_remaining: 50, rate_limit_low: true })

      logger = instance_double(Logger, info: nil)
      allow(Temporalio::Workflow).to receive(:logger).and_return(logger)

      workflow.send(:maybe_run_non_critical_activities, 1)

      expect(workflow).not_to have_received(:run_activity)
        .with(Activities::ScanPaidPrsActivity, anything, timeout: anything)
      expect(workflow).not_to have_received(:run_activity)
        .with(Activities::ScanSecurityAlertsActivity, anything, timeout: anything)
      expect(workflow).not_to have_received(:run_activity)
        .with(Activities::CheckKnowledgeStalenessActivity, anything, timeout: anything)
      expect(logger).to have_received(:info).with(hash_including(
        message: "poll.non_critical_skipped_budget_low",
        project_id: 1,
        rate_limit_remaining: 50
      ))
    end

    it "runs non-critical activities when rate limit is sufficient" do
      allow(workflow).to receive(:run_activity)
        .with(Activities::CheckRateLimitActivity, anything, timeout: anything)
        .and_return({ rate_limit_remaining: 500, rate_limit_low: false })
      allow(workflow).to receive(:run_activity)
        .with(Activities::ScanPaidPrsActivity, anything, timeout: anything)
        .and_return({ prs_to_trigger: [] })

      workflow.send(:maybe_run_non_critical_activities, 1)

      expect(workflow).to have_received(:run_activity)
        .with(Activities::ScanPaidPrsActivity, { project_id: 1 }, timeout: 120)
    end

    it "skips rate limit check but still runs non-critical activities when patch guard returns false (pre-v872 workflows)" do
      allow(Temporalio::Workflow).to receive(:patched).with("add-rate-limit-budget-v1").and_return(false)
      allow(workflow).to receive(:run_activity)
        .with(Activities::ScanPaidPrsActivity, anything, timeout: anything)
        .and_return({ prs_to_trigger: [] })

      workflow.send(:maybe_run_non_critical_activities, 1)

      expect(workflow).not_to have_received(:run_activity)
        .with(Activities::CheckRateLimitActivity, anything, timeout: anything)
      expect(workflow).to have_received(:run_activity)
        .with(Activities::ScanPaidPrsActivity, { project_id: 1 }, timeout: 120)
    end
  end

  describe "CheckKnowledgeStalenessActivity patch guard" do
    let(:workflow) { described_class.new }

    before do
      allow(workflow).to receive(:run_activity).and_return({})
    end

    it "runs CheckKnowledgeStalenessActivity when patched returns true" do
      allow(Temporalio::Workflow).to receive(:patched).with("add-check-knowledge-staleness-v1").and_return(true)

      workflow.send(:maybe_check_knowledge_staleness, 1)

      expect(workflow).to have_received(:run_activity)
        .with(Activities::CheckKnowledgeStalenessActivity, { project_id: 1 }, timeout: 30)
    end

    it "skips CheckKnowledgeStalenessActivity when patched returns false" do
      allow(Temporalio::Workflow).to receive(:patched).with("add-check-knowledge-staleness-v1").and_return(false)

      workflow.send(:maybe_check_knowledge_staleness, 1)

      expect(workflow).not_to have_received(:run_activity)
        .with(Activities::CheckKnowledgeStalenessActivity, anything, timeout: anything)
    end
  end

  describe "EvaluateAutoReleaseActivity patch guard" do
    let(:workflow) { described_class.new }

    before do
      allow(workflow).to receive(:run_activity).and_return({})
    end

    it "runs EvaluateAutoReleaseActivity when patched returns true" do
      allow(Temporalio::Workflow).to receive(:patched).with("add-auto-release-poll-v1").and_return(true)

      workflow.send(:maybe_evaluate_auto_release, 1)

      expect(workflow).to have_received(:run_activity)
        .with(Activities::EvaluateAutoReleaseActivity, { project_id: 1 }, timeout: 30)
    end

    it "skips EvaluateAutoReleaseActivity when patched returns false" do
      allow(Temporalio::Workflow).to receive(:patched).with("add-auto-release-poll-v1").and_return(false)

      workflow.send(:maybe_evaluate_auto_release, 1)

      expect(workflow).not_to have_received(:run_activity)
        .with(Activities::EvaluateAutoReleaseActivity, anything, timeout: anything)
    end
  end

  describe "ScanSecurityAlertsActivity error handling" do
    let(:workflow) { described_class.new }

    before do
      allow(Temporalio::Workflow).to receive(:patched)
        .with("add-scan-security-alerts-v1").and_return(true)
      allow(Temporalio::Workflow).to receive(:patched)
        .with("add-rate-limit-budget-v1").and_return(false)
      allow(Temporalio::Workflow).to receive(:patched)
        .with(anything).and_return(true)
    end

    def activity_error_with_cause(cause)
      begin
        begin
          raise cause
        rescue
          raise Temporalio::Error::ActivityError.new(
            "activity failed",
            scheduled_event_id: 1, started_event_id: 2, identity: "",
            activity_type: "ScanSecurityAlerts", activity_id: "1",
            retry_state: Temporalio::Error::RetryState::NON_RETRYABLE_FAILURE
          )
        end
      rescue => e
        e
      end
    end

    it "swallows ConfigurationError and continues the poll cycle" do
      config_error = Temporalio::Error::ApplicationError.new(
        "Token lacks security_events scope",
        type: "ConfigurationError",
        non_retryable: true
      )
      activity_error = activity_error_with_cause(config_error)
      allow(workflow).to receive(:run_activity)
        .with(Activities::ScanSecurityAlertsActivity, anything, timeout: anything)
        .and_raise(activity_error)

      logger = instance_double(Logger, warn: nil)
      allow(Temporalio::Workflow).to receive(:logger).and_return(logger)

      expect { workflow.send(:maybe_scan_code_scanning_alerts, 1) }.not_to raise_error

      expect(logger).to have_received(:warn).with(hash_including(
        message: "poll.code_scanning_configuration_error",
        project_id: 1
      ))
    end

    it "re-raises non-ConfigurationError ActivityErrors" do
      other_error = Temporalio::Error::ApplicationError.new(
        "Something else",
        type: "OtherError",
        non_retryable: true
      )
      activity_error = activity_error_with_cause(other_error)
      allow(workflow).to receive(:run_activity)
        .with(Activities::ScanSecurityAlertsActivity, anything, timeout: anything)
        .and_raise(activity_error)

      expect { workflow.send(:maybe_scan_code_scanning_alerts, 1) }
        .to raise_error(Temporalio::Error::ActivityError)
    end
  end

  describe "#handle_automation_result" do
    let(:workflow) { described_class.new }
    let(:project_id) { 1 }

    before do
      allow(workflow).to receive(:run_activity)
        .with(Activities::QueueAgentRunActivity, anything, timeout: anything)
        .and_return({ queued: true })
      allow(Temporalio::Workflow).to receive(:start_child_workflow)
      allow(Temporalio::Workflow).to receive(:patched)
        .with("queue-agent-run-goal-v1")
        .and_return(true)
    end

    it "queues explicit create_pr decisions instead of starting runs directly" do
      evaluation = { decisions: [ { type: "queue_create_pr_run", issue_id: 10 } ] }

      workflow.send(:handle_automation_result, evaluation, project_id)

      expect(workflow).to have_received(:run_activity)
        .with(Activities::QueueAgentRunActivity, { project_id: project_id, issue_id: 10, goal: "create_pr" }, timeout: 30)
      expect(Temporalio::Workflow).not_to have_received(:start_child_workflow)
    end

    it "queues create_pr explicitly for PR decisions" do
      evaluation = { decisions: [ { type: "queue_create_pr_run", issue_id: 10, source_pull_request_number: 42 } ] }

      workflow.send(:handle_automation_result, evaluation, project_id)

      expect(workflow).to have_received(:run_activity)
        .with(Activities::QueueAgentRunActivity,
          { project_id: project_id, issue_id: 10, source_pull_request_number: 42, goal: "create_pr" },
          timeout: 30)
    end

    it "queues analyze_issue run for queue_analyze_issue_run decisions" do
      evaluation = { decisions: [ { type: "queue_analyze_issue_run", issue_id: 10 } ] }

      workflow.send(:handle_automation_result, evaluation, project_id)

      expect(workflow).to have_received(:run_activity)
        .with(Activities::QueueAgentRunActivity, { project_id: project_id, issue_id: 10, goal: "analyze_issue" }, timeout: 30)
    end

    it "starts PlanningWorkflow for start_planning decisions" do
      evaluation = { decisions: [ { type: "start_planning", issue_id: 20 } ] }

      allow(workflow).to receive(:run_activity)
        .with(Activities::CheckRunCapacityActivity, anything, timeout: anything)
        .and_return({ has_capacity: true })
      allow(Temporalio::Workflow).to receive(:now).and_return(Time.now)

      workflow.send(:handle_automation_result, evaluation, project_id)

      expect(Temporalio::Workflow).to have_received(:start_child_workflow).with(
        Workflows::PlanningWorkflow,
        { project_id: project_id, issue_id: 20 },
        hash_including(
          id: /\Aplan-#{project_id}-20-/,
          parent_close_policy: Temporalio::Workflow::ParentClosePolicy::ABANDON
        )
      )
    end

    it "defers planning to future poll cycle when at capacity" do
      logger = instance_double(Logger, info: nil)
      allow(Temporalio::Workflow).to receive(:logger).and_return(logger)

      allow(workflow).to receive(:run_activity)
        .with(Activities::CheckRunCapacityActivity, anything, timeout: anything)
        .and_return({ has_capacity: false })

      evaluation = { decisions: [ { type: "start_planning", issue_id: 20 } ] }
      workflow.send(:handle_automation_result, evaluation, project_id)

      expect(logger).to have_received(:info).with(hash_including(
        message: "planning.deferred_due_to_capacity",
        project_id: project_id,
        issue_id: 20
      ))
      expect(Temporalio::Workflow).not_to have_received(:start_child_workflow)
    end

    it "skips queueing when the quality gate blocks the run" do
      allow(workflow).to receive(:quality_gate_allows_run?).and_return(false)

      evaluation = { decisions: [ { type: "queue_create_pr_run", issue_id: 10 } ] }
      workflow.send(:handle_automation_result, evaluation, project_id)

      expect(workflow).not_to have_received(:run_activity)
        .with(Activities::QueueAgentRunActivity, anything, timeout: anything)
    end
  end

  describe "#queue_enhance_issue_rechecks" do
    let(:workflow) { described_class.new }

    before do
      allow(workflow).to receive(:run_activity)
    end

    it "queues enhance_issue runs for recheck requests" do
      workflow.send(:queue_enhance_issue_rechecks, 1, [ { issue_id: 42 } ])

      expect(workflow).to have_received(:run_activity).with(
        Activities::QueueAgentRunActivity,
        { project_id: 1, issue_id: 42, goal: "enhance_issue" },
        timeout: 30
      )
    end
  end

  describe "#handle_pr_trigger" do
    let(:workflow) { described_class.new }
    let(:project_id) { 1 }

    def draft_pr_data(current_draft_review_count:, triggers:)
      {
        issue_id: 10,
        pr_number: 42,
        phase: "draft",
        current_draft_review_count: current_draft_review_count,
        triggers: triggers
      }
    end

    def expected_draft_queue_input(count:)
      {
        project_id: project_id,
        issue_id: 10,
        source_pull_request_number: 42,
        goal: "create_pr",
        count_toward_draft_review_round: true,
        expected_draft_review_count: count
      }
    end

    def expected_review_queue_input
      {
        project_id: project_id,
        issue_id: 10,
        source_pull_request_number: 42,
        goal: "review"
      }
    end

    before do
      allow(workflow).to receive(:run_activity).and_return({})
      allow(Temporalio::Workflow).to receive(:start_child_workflow)
      allow(Temporalio::Workflow).to receive(:patched)
        .with("draft-followup-direct-start-v1")
        .and_return(true)
      allow(Temporalio::Workflow).to receive(:patched)
        .with("escalation-reason-payload-v1")
        .and_return(true)
      allow(Temporalio::Workflow).to receive(:patched)
        .with("queue-agent-run-goal-v1")
        .and_return(true)
      allow(Temporalio::Workflow).to receive(:patched)
        .with("queue-paid-agent-review-run-v1")
        .and_return(true)
      allow(Temporalio::Workflow).to receive(:patched)
        .with("pause-followup-during-review-v1")
        .and_return(true)
      allow(Temporalio::Workflow).to receive(:patched)
        .with("pause-review-bot-followup-during-review-v1")
        .and_return(true)
    end

    it "routes ready_for_owner to MarkPrReadyActivity and RequestReviewActivity" do
      allow(workflow).to receive(:run_activity)
        .with(Activities::MarkPrReadyActivity, anything, timeout: anything)
        .and_return({ marked_ready: true })

      pr_data = {
        issue_id: 10, pr_number: 42, owner_reviewer_login: "viamin",
        triggers: [ { type: "ready_for_owner" } ]
      }

      workflow.send(:handle_pr_trigger, project_id, pr_data)

      expect(workflow).to have_received(:run_activity)
        .with(Activities::MarkPrReadyActivity, hash_including(pr_number: 42), timeout: anything)
      expect(workflow).to have_received(:run_activity)
        .with(Activities::RequestReviewActivity, hash_including(reviewers: [ "viamin" ]), timeout: anything)
    end

    it "queues paid_agent review sidecar when bundled with ready_for_owner" do
      allow(workflow).to receive(:run_activity)
        .with(Activities::MarkPrReadyActivity, anything, timeout: anything)
        .and_return({ marked_ready: true })

      pr_data = {
        issue_id: 10, pr_number: 42, owner_reviewer_login: "viamin",
        triggers: [
          { type: "ready_for_owner" },
          { type: "paid_agent_review_pending" }
        ]
      }

      workflow.send(:handle_pr_trigger, project_id, pr_data)

      expect(workflow).to have_received(:run_activity)
        .with(Activities::QueueAgentRunActivity,
          hash_including(project_id: 1, issue_id: 10,
            source_pull_request_number: 42, goal: "review"),
          timeout: anything)
      expect(workflow).to have_received(:run_activity)
        .with(Activities::MarkPrReadyActivity, hash_including(pr_number: 42), timeout: anything)
      expect(workflow).to have_received(:run_activity)
        .with(Activities::RequestReviewActivity, hash_including(reviewers: [ "viamin" ]), timeout: anything)
    end

    it "skips owner review when MarkPrReadyActivity returns marked_ready: false" do
      allow(workflow).to receive(:run_activity)
        .with(Activities::MarkPrReadyActivity, anything, timeout: anything)
        .and_return({ marked_ready: false })

      pr_data = {
        issue_id: 10, pr_number: 42, owner_reviewer_login: "viamin",
        triggers: [ { type: "ready_for_owner" } ]
      }

      workflow.send(:handle_pr_trigger, project_id, pr_data)

      expect(workflow).not_to have_received(:run_activity)
        .with(Activities::RequestReviewActivity, anything, timeout: anything)
    end

    it "routes escalate_to_owner to MarkEscalatedActivity and RequestReviewActivity" do
      pr_data = {
        issue_id: 10, pr_number: 42, owner_reviewer_login: "viamin",
        triggers: [ { type: "escalate_to_owner" } ]
      }

      workflow.send(:handle_pr_trigger, project_id, pr_data)

      expect(workflow).to have_received(:run_activity)
        .with(Activities::MarkEscalatedActivity, hash_including(issue_id: 10), timeout: anything)
      expect(workflow).to have_received(:run_activity)
        .with(Activities::RequestReviewActivity, hash_including(reviewers: [ "viamin" ]), timeout: anything)
    end

    it "forwards escalation reason from trigger details to MarkEscalatedActivity" do
      pr_data = {
        issue_id: 10, pr_number: 42, owner_reviewer_login: "viamin",
        triggers: [ { type: "escalate_to_owner", details: "Draft review limit reached" } ]
      }

      workflow.send(:handle_pr_trigger, project_id, pr_data)

      expect(workflow).to have_received(:run_activity)
        .with(Activities::MarkEscalatedActivity,
          { issue_id: 10, reason: "Draft review limit reached" }, timeout: anything)
    end

    it "omits reason key when trigger has no details" do
      pr_data = {
        issue_id: 10, pr_number: 42, owner_reviewer_login: "viamin",
        triggers: [ { type: "escalate_to_owner" } ]
      }

      workflow.send(:handle_pr_trigger, project_id, pr_data)

      expect(workflow).to have_received(:run_activity)
        .with(Activities::MarkEscalatedActivity,
          { issue_id: 10 }, timeout: anything)
    end

    it "sends old payload without reason before the escalation-reason patch" do
      allow(Temporalio::Workflow).to receive(:patched)
        .with("escalation-reason-payload-v1")
        .and_return(false)

      pr_data = {
        issue_id: 10, pr_number: 42, owner_reviewer_login: "viamin",
        triggers: [ { type: "escalate_to_owner", details: "Draft review limit reached" } ]
      }

      workflow.send(:handle_pr_trigger, project_id, pr_data)

      expect(workflow).to have_received(:run_activity)
        .with(Activities::MarkEscalatedActivity,
          { issue_id: 10 }, timeout: anything)
    end

    it "routes dismiss_escalation to DismissEscalationActivity and queues a fresh ready-phase follow-up" do
      allow(workflow).to receive(:run_activity)
        .with(Activities::DismissEscalationActivity, anything, timeout: anything)
        .and_return({
          dismissed: true,
          issue_id: 10,
          pr_number: 42,
          phase: "ready",
          current_followup_count: 0
        })

      pr_data = {
        issue_id: 10, pr_number: 42,
        triggers: [ { type: "dismiss_escalation" } ]
      }

      workflow.send(:handle_pr_trigger, project_id, pr_data)

      expect(workflow).to have_received(:run_activity)
        .with(Activities::DismissEscalationActivity, hash_including(issue_id: 10), timeout: anything)
      expect(workflow).to have_received(:run_activity)
        .with(Activities::QueueAgentRunActivity,
          { project_id: project_id, issue_id: 10, source_pull_request_number: 42, goal: "create_pr" },
          timeout: 30)
    end

    it "queues a fresh draft-cycle follow-up when dismissal resumes a restarted draft PR" do
      allow(workflow).to receive(:run_activity)
        .with(Activities::DismissEscalationActivity, anything, timeout: anything)
        .and_return({
          dismissed: true,
          issue_id: 10,
          pr_number: 42,
          phase: "restarted",
          current_draft_review_count: 0,
          current_followup_count: 0
        })

      pr_data = {
        issue_id: 10, pr_number: 42, draft: true,
        triggers: [ { type: "dismiss_escalation" } ]
      }

      workflow.send(:handle_pr_trigger, project_id, pr_data)

      expect(workflow).to have_received(:run_activity)
        .with(Activities::QueueAgentRunActivity, expected_draft_queue_input(count: 0), timeout: 30)
    end

    it "prioritizes escalate_to_owner over review_goal_retry in mixed payloads" do
      pr_data = {
        issue_id: 10, pr_number: 42, owner_reviewer_login: "viamin",
        triggers: [
          { type: "review_goal_retry", details: "Retrying failed review" },
          { type: "escalate_to_owner", details: "Draft review limit reached" }
        ]
      }

      workflow.send(:handle_pr_trigger, project_id, pr_data)

      expect(workflow).to have_received(:run_activity)
        .with(Activities::MarkEscalatedActivity, hash_including(issue_id: 10), timeout: anything)
      expect(workflow).not_to have_received(:run_activity)
        .with(Activities::RecordReviewGoalRetryActivity, anything, timeout: anything)
    end

    it "prioritizes dismiss_escalation over review_goal_retry in mixed payloads" do
      pr_data = {
        issue_id: 10, pr_number: 42,
        triggers: [
          { type: "review_goal_retry", details: "Retrying failed review" },
          { type: "dismiss_escalation" }
        ]
      }

      workflow.send(:handle_pr_trigger, project_id, pr_data)

      expect(workflow).to have_received(:run_activity)
        .with(Activities::DismissEscalationActivity, hash_including(issue_id: 10), timeout: anything)
      expect(workflow).not_to have_received(:run_activity)
        .with(Activities::RecordReviewGoalRetryActivity, anything, timeout: anything)
    end

    it "routes owner_approved to MergePullRequestActivity" do
      pr_data = {
        issue_id: 10, pr_number: 42,
        triggers: [ { type: "owner_approved" } ]
      }

      workflow.send(:handle_pr_trigger, project_id, pr_data)

      expect(workflow).to have_received(:run_activity)
        .with(Activities::MergePullRequestActivity, hash_including(pr_number: 42), timeout: anything)
    end

    it "routes draft phase triggers to draft followup workflow" do
      workflow.send(:handle_pr_trigger, project_id,
        draft_pr_data(current_draft_review_count: 1, triggers: [ { type: "ci_failure" } ]))

      expect(workflow).to have_received(:run_activity)
        .with(Activities::QueueAgentRunActivity, expected_draft_queue_input(count: 1), timeout: 30)
      expect(workflow).not_to have_received(:run_activity)
        .with(Activities::CheckRunCapacityActivity, anything, timeout: anything)
      expect(Temporalio::Workflow).not_to have_received(:start_child_workflow)
    end

    it "replays the legacy draft followup command sequence before the patch" do
      allow(Temporalio::Workflow).to receive(:patched)
        .with("draft-followup-direct-start-v1")
        .and_return(false)

      workflow.send(:handle_pr_trigger, project_id,
        draft_pr_data(current_draft_review_count: 1, triggers: [ { type: "ci_failure" } ]))

      expect(workflow).to have_received(:run_activity)
        .with(Activities::QueueAgentRunActivity,
          { project_id: project_id, issue_id: 10, source_pull_request_number: 42, goal: "create_pr" },
          timeout: 30)
      expect(workflow).to have_received(:run_activity)
        .with(Activities::RecordDraftReviewActivity,
          { issue_id: 10, expected_draft_review_count: 1 }, timeout: 30)
      expect(workflow).not_to have_received(:run_activity)
        .with(Activities::CheckRunCapacityActivity, anything, timeout: anything)
      expect(Temporalio::Workflow).not_to have_received(:start_child_workflow)
    end

    it "omits goal from legacy draft followup queue input before the goal patch" do
      allow(Temporalio::Workflow).to receive(:patched)
        .with("draft-followup-direct-start-v1")
        .and_return(false)
      allow(Temporalio::Workflow).to receive(:patched)
        .with("queue-agent-run-goal-v1")
        .and_return(false)

      workflow.send(:handle_pr_trigger, project_id,
        draft_pr_data(current_draft_review_count: 1, triggers: [ { type: "ci_failure" } ]))

      expect(workflow).to have_received(:run_activity)
        .with(Activities::QueueAgentRunActivity,
          { project_id: project_id, issue_id: 10, source_pull_request_number: 42 },
          timeout: 30)
    end

    it "omits goal from patched draft followup queue input before the goal patch" do
      allow(Temporalio::Workflow).to receive(:patched)
        .with("queue-agent-run-goal-v1")
        .and_return(false)

      workflow.send(:handle_pr_trigger, project_id,
        draft_pr_data(current_draft_review_count: 1, triggers: [ { type: "ci_failure" } ]))

      expect(workflow).to have_received(:run_activity)
        .with(Activities::QueueAgentRunActivity,
          { project_id: project_id, issue_id: 10,
            source_pull_request_number: 42,
            count_toward_draft_review_round: true,
            expected_draft_review_count: 1 }, timeout: 30)
    end

    it "queues draft followup runs without incrementing draft review count yet" do
      workflow.send(:handle_pr_trigger, project_id,
        draft_pr_data(current_draft_review_count: 4, triggers: [ { type: "ci_failure" } ]))

      expect(workflow).to have_received(:run_activity)
        .with(
          Activities::QueueAgentRunActivity,
          expected_draft_queue_input(count: 4),
          timeout: 30
        )
      expect(workflow).not_to have_received(:run_activity)
        .with(Activities::RecordDraftReviewActivity, anything, timeout: anything)
    end

    it "preserves draft-round metadata when a draft followup deduplicates" do
      allow(workflow).to receive(:run_activity)
        .with(Activities::QueueAgentRunActivity, expected_draft_queue_input(count: 2), timeout: 30)
        .and_return({ agent_run_id: 456, queued: false, duplicate: true })

      workflow.send(:handle_pr_trigger, project_id,
        draft_pr_data(current_draft_review_count: 2, triggers: [ { type: "review_threads" } ]))

      expect(workflow).to have_received(:run_activity)
        .with(Activities::QueueAgentRunActivity, expected_draft_queue_input(count: 2), timeout: 30)
      expect(Temporalio::Workflow).not_to have_received(:start_child_workflow)
    end

    it "routes ready phase triggers to PR followup workflow" do
      allow(workflow).to receive(:run_activity)
        .with(Activities::QueueAgentRunActivity, anything, timeout: anything)
        .and_return({ queued: true })

      pr_data = {
        issue_id: 10, pr_number: 42, phase: "ready",
        current_followup_count: 0,
        triggers: [ { type: "ci_failure" } ]
      }

      workflow.send(:handle_pr_trigger, project_id, pr_data)

      expect(workflow).to have_received(:run_activity)
        .with(Activities::QueueAgentRunActivity,
          { project_id: project_id, issue_id: 10, source_pull_request_number: 42, goal: "create_pr" }, timeout: 30)
      expect(Temporalio::Workflow).not_to have_received(:start_child_workflow)
    end

    it "omits goal from ready-phase followup queue input before the goal patch" do
      allow(Temporalio::Workflow).to receive(:patched)
        .with("queue-agent-run-goal-v1")
        .and_return(false)
      allow(workflow).to receive(:run_activity)
        .with(Activities::QueueAgentRunActivity, anything, timeout: anything)
        .and_return({ queued: true })

      pr_data = {
        issue_id: 10, pr_number: 42, phase: "ready",
        current_followup_count: 0,
        triggers: [ { type: "ci_failure" } ]
      }

      workflow.send(:handle_pr_trigger, project_id, pr_data)

      expect(workflow).to have_received(:run_activity)
        .with(Activities::QueueAgentRunActivity,
          { project_id: project_id, issue_id: 10, source_pull_request_number: 42 }, timeout: 30)
    end

    it "routes review_bot_review_pending to RequestReviewActivity using the trigger's request_login" do
      pr_data = {
        issue_id: 10, pr_number: 42, phase: "draft",
        current_draft_review_count: 0,
        triggers: [ { type: "review_bot_review_pending", request_login: Activities::RequestReviewActivity::COPILOT_LOGIN } ]
      }

      workflow.send(:handle_pr_trigger, project_id, pr_data)

      expect(workflow).to have_received(:run_activity)
        .with(Activities::RequestReviewActivity,
          hash_including(reviewers: [ Activities::RequestReviewActivity::COPILOT_LOGIN ]), timeout: anything)
    end

    it "skips review request when review_bot_review_pending has no request_login (auto-review bots)" do
      pr_data = {
        issue_id: 10, pr_number: 42, phase: "draft",
        current_draft_review_count: 0,
        triggers: [ { type: "review_bot_review_pending", request_login: nil } ]
      }

      workflow.send(:handle_pr_trigger, project_id, pr_data)

      expect(workflow).not_to have_received(:run_activity)
        .with(Activities::RequestReviewActivity, anything, timeout: anything)
    end

    it "forwards the full request_logins chain so RequestReviewActivity can fall back" do
      chain = [ Activities::RequestReviewActivity::COPILOT_LOGIN,
                Activities::RequestReviewActivity::CODEX_LOGIN ]
      pr_data = {
        issue_id: 10, pr_number: 42, phase: "draft",
        current_draft_review_count: 0,
        triggers: [ { type: "review_bot_review_pending",
                      request_login: chain.first, request_logins: chain } ]
      }

      workflow.send(:handle_pr_trigger, project_id, pr_data)

      expect(workflow).to have_received(:run_activity)
        .with(Activities::RequestReviewActivity, hash_including(reviewers: chain), timeout: anything)
    end

    it "requests review and suppresses draft followup when other triggers are present in draft" do
      pr_data = {
        issue_id: 10, pr_number: 42, phase: "draft",
        current_draft_review_count: 1,
        triggers: [
          { type: "review_bot_review_pending", request_login: Activities::RequestReviewActivity::COPILOT_LOGIN },
          { type: "review_threads" }
        ]
      }

      workflow.send(:handle_pr_trigger, project_id, pr_data)

      expect(workflow).to have_received(:run_activity)
        .with(Activities::RequestReviewActivity,
          hash_including(reviewers: array_including(Activities::RequestReviewActivity::COPILOT_LOGIN)), timeout: anything)
      expect(workflow).not_to have_received(:run_activity)
        .with(Activities::QueueAgentRunActivity, hash_including(goal: "create_pr"), timeout: anything)
    end

    it "does not start followup workflow when review_bot_review_pending is the only trigger" do
      allow(Temporalio::Workflow).to receive(:start_child_workflow)

      pr_data = {
        issue_id: 10, pr_number: 42, phase: "draft",
        current_draft_review_count: 0,
        triggers: [ { type: "review_bot_review_pending" } ]
      }

      workflow.send(:handle_pr_trigger, project_id, pr_data)

      expect(Temporalio::Workflow).not_to have_received(:start_child_workflow)
    end

    it "requests review and suppresses ready-phase followup when review_bot_review_pending is bundled with actionable triggers" do
      pr_data = {
        issue_id: 10, pr_number: 42, phase: "ready",
        triggers: [
          { type: "review_bot_review_pending", request_login: Activities::RequestReviewActivity::COPILOT_LOGIN },
          { type: "ci_failure", details: [ "rspec" ] }
        ]
      }

      workflow.send(:handle_pr_trigger, project_id, pr_data)

      expect(workflow).to have_received(:run_activity)
        .with(Activities::RequestReviewActivity,
          hash_including(reviewers: array_including(Activities::RequestReviewActivity::COPILOT_LOGIN)), timeout: anything)
      expect(workflow).not_to have_received(:run_activity)
        .with(Activities::QueueAgentRunActivity, hash_including(goal: "create_pr"), timeout: anything)
      expect(workflow).not_to have_received(:run_activity)
        .with(Activities::RecordPrFollowupActivity, anything, timeout: anything)
    end

    it "suppresses create_pr followup for stale auto-review bot signals with no request login" do
      pr_data = {
        issue_id: 10, pr_number: 42, phase: "ready",
        current_followup_count: 0,
        triggers: [
          { type: "review_bot_review_pending", request_login: nil },
          { type: "ci_failure", details: [ "rspec" ] }
        ]
      }

      workflow.send(:handle_pr_trigger, project_id, pr_data)

      expect(workflow).not_to have_received(:run_activity)
        .with(Activities::RequestReviewActivity, anything, timeout: anything)
      expect(workflow).not_to have_received(:run_activity)
        .with(Activities::QueueAgentRunActivity, hash_including(goal: "create_pr"), timeout: anything)
      expect(workflow).not_to have_received(:run_activity)
        .with(Activities::RecordPrFollowupActivity, anything, timeout: anything)
    end

    it "keeps ready-phase followup for posted bot feedback while review_bot_review_pending is outstanding" do
      pr_data = {
        issue_id: 10, pr_number: 42, phase: "ready",
        current_followup_count: 0,
        triggers: [
          { type: "review_bot_review_pending", request_login: Activities::RequestReviewActivity::COPILOT_LOGIN },
          { type: "review_bot_threads", details: [ "Address review thread" ] }
        ]
      }

      workflow.send(:handle_pr_trigger, project_id, pr_data)

      expect(workflow).to have_received(:run_activity)
        .with(Activities::RequestReviewActivity,
          hash_including(reviewers: array_including(Activities::RequestReviewActivity::COPILOT_LOGIN)), timeout: anything)
      expect(workflow).to have_received(:run_activity)
        .with(Activities::QueueAgentRunActivity, hash_including(goal: "create_pr"), timeout: anything)
      expect(workflow).to have_received(:run_activity)
        .with(Activities::RecordPrFollowupActivity, hash_including(issue_id: 10), timeout: anything)
    end

    it "preserves ready-phase replay order before the review pending hard gate patch" do
      allow(Temporalio::Workflow).to receive(:patched)
        .with("pause-review-bot-followup-during-review-v1")
        .and_return(false)

      pr_data = {
        issue_id: 10, pr_number: 42, phase: "ready",
        current_followup_count: 0,
        triggers: [
          { type: "review_bot_review_pending", request_login: Activities::RequestReviewActivity::COPILOT_LOGIN },
          { type: "ci_failure", details: [ "rspec" ] }
        ]
      }

      workflow.send(:handle_pr_trigger, project_id, pr_data)

      expect(workflow).not_to have_received(:run_activity)
        .with(Activities::RequestReviewActivity, anything, timeout: anything)
      expect(workflow).to have_received(:run_activity)
        .with(Activities::RecordPrFollowupActivity, hash_including(issue_id: 10), timeout: anything)
    end

    it "triggers dev environment update after successful merge" do
      allow(Temporalio::Workflow).to receive(:patched).with("add-dev-environment-update-v1").and_return(true)

      pr_data = {
        issue_id: 10, pr_number: 42,
        triggers: [ { type: "owner_approved" } ]
      }

      allow(workflow).to receive(:run_activity)
        .with(Activities::MergePullRequestActivity, anything, timeout: anything)
        .and_return({ merged: true })
      allow(workflow).to receive(:run_activity)
        .with(Activities::TriggerDevEnvironmentUpdateActivity, anything, timeout: anything)
        .and_return({})

      workflow.send(:handle_pr_trigger, project_id, pr_data)

      expect(workflow).to have_received(:run_activity)
        .with(Activities::TriggerDevEnvironmentUpdateActivity,
          { project_id: project_id, pr_number: 42 }, timeout: 60)
    end

    it "skips dev environment update when patch is disabled" do
      allow(Temporalio::Workflow).to receive(:patched).with("add-dev-environment-update-v1").and_return(false)

      pr_data = {
        issue_id: 10, pr_number: 42,
        triggers: [ { type: "owner_approved" } ]
      }

      allow(workflow).to receive(:run_activity)
        .with(Activities::MergePullRequestActivity, anything, timeout: anything)
        .and_return({ merged: true })

      workflow.send(:handle_pr_trigger, project_id, pr_data)

      expect(workflow).not_to have_received(:run_activity)
        .with(Activities::TriggerDevEnvironmentUpdateActivity, anything, timeout: anything)
    end

    it "skips dev environment update when merge fails" do
      pr_data = {
        issue_id: 10, pr_number: 42,
        triggers: [ { type: "owner_approved" } ]
      }

      allow(workflow).to receive(:run_activity)
        .with(Activities::MergePullRequestActivity, anything, timeout: anything)
        .and_return({ merged: false })

      workflow.send(:handle_pr_trigger, project_id, pr_data)

      expect(workflow).not_to have_received(:run_activity)
        .with(Activities::TriggerDevEnvironmentUpdateActivity, anything, timeout: anything)
    end

    it "routes manual_review_pending to RequestReviewActivity with configured reviewer" do
      pr_data = {
        issue_id: 10, pr_number: 42, phase: "draft",
        triggers: [ { type: "manual_review_pending", reviewer_login: "alice" } ]
      }

      workflow.send(:handle_pr_trigger, project_id, pr_data)

      expect(workflow).to have_received(:run_activity)
        .with(Activities::RequestReviewActivity,
          hash_including(reviewers: [ "alice" ]), timeout: anything)
    end

    it "does not start a followup workflow for ci_action_pending alone" do
      pr_data = {
        issue_id: 10, pr_number: 42, phase: "draft",
        triggers: [ { type: "ci_action_pending", action_name: "e2e-suite" } ]
      }

      workflow.send(:handle_pr_trigger, project_id, pr_data)

      expect(Temporalio::Workflow).not_to have_received(:start_child_workflow)
    end

    it "dispatches Claude review when ci_action_pending requests it" do
      pr_data = {
        issue_id: 10, pr_number: 42, phase: "draft",
        triggers: [ { type: "ci_action_pending", action_name: "Claude Code Review", dispatch_required: true } ]
      }

      workflow.send(:handle_pr_trigger, project_id, pr_data)

      expect(workflow).to have_received(:run_activity)
        .with(Activities::DispatchClaudeReviewActivity,
          { project_id: project_id, pr_number: 42 }, timeout: 60)
      expect(Temporalio::Workflow).not_to have_received(:start_child_workflow)
    end

    it "dispatches Claude review and still starts followup when other triggers are present" do
      pr_data = {
        issue_id: 10, pr_number: 42, phase: "draft",
        triggers: [
          { type: "ci_action_pending", action_name: "Claude Code Review", dispatch_required: true },
          { type: "ci_failure", details: [ "rspec" ] }
        ],
        current_draft_review_count: 0
      }

      workflow.send(:handle_pr_trigger, project_id, pr_data)

      expect(workflow).to have_received(:run_activity)
        .with(Activities::DispatchClaudeReviewActivity,
          { project_id: project_id, pr_number: 42 }, timeout: 60)
      expect(workflow).to have_received(:run_activity)
        .with(Activities::QueueAgentRunActivity,
          hash_including(count_toward_draft_review_round: true, expected_draft_review_count: 0),
          timeout: anything)
    end

    it "starts followup when manual_review_pending is combined with other triggers" do
      pr_data = {
        issue_id: 10, pr_number: 42, phase: "draft",
        triggers: [
          { type: "manual_review_pending", reviewer_login: "alice" },
          { type: "ci_failure", details: [ "rspec" ] }
        ],
        current_draft_review_count: 0
      }

      workflow.send(:handle_pr_trigger, project_id, pr_data)

      expect(workflow).to have_received(:run_activity)
        .with(Activities::RequestReviewActivity,
          hash_including(reviewers: [ "alice" ]), timeout: anything)
      # Verify draft followup specifically (not ready followup) via
      # RecordDraftReviewActivity which only start_draft_followup_workflow calls.
      expect(workflow).to have_received(:run_activity)
        .with(Activities::QueueAgentRunActivity,
          hash_including(count_toward_draft_review_round: true, expected_draft_review_count: 0),
          timeout: anything)
    end

    it "routes review_goal_retry to RecordReviewGoalRetryActivity and QueueAgentRunActivity with review goal" do
      pr_data = {
        issue_id: 10, pr_number: 42, phase: "draft",
        triggers: [ { type: "review_goal_retry", details: "Retrying failed review-goal run" } ],
        current_review_goal_retry_count: 1
      }

      workflow.send(:handle_pr_trigger, project_id, pr_data)

      expect(workflow).to have_received(:run_activity)
        .with(Activities::RecordReviewGoalRetryActivity,
          hash_including(issue_id: 10, expected_review_goal_retry_count: 1), timeout: anything)
      expect(workflow).to have_received(:run_activity)
        .with(Activities::QueueAgentRunActivity,
          hash_including(
            project_id: project_id,
            issue_id: 10,
            source_pull_request_number: 42,
            goal: "review"
          ), timeout: anything)
    end

    it "starts draft followup when review_goal_retry is combined with actionable triggers" do
      pr_data = {
        issue_id: 10, pr_number: 42, phase: "draft",
        triggers: [
          { type: "review_goal_retry", details: "Retrying failed review-goal run" },
          { type: "ci_failure", details: [ "rspec" ] }
        ],
        current_review_goal_retry_count: 1,
        current_draft_review_count: 2
      }

      workflow.send(:handle_pr_trigger, project_id, pr_data)

      expect(workflow).to have_received(:run_activity)
        .with(Activities::RecordReviewGoalRetryActivity,
          hash_including(issue_id: 10, expected_review_goal_retry_count: 1), timeout: anything)
      expect(workflow).to have_received(:run_activity)
        .with(Activities::QueueAgentRunActivity,
          hash_including(goal: "review"), timeout: anything)
      expect(workflow).to have_received(:run_activity)
        .with(Activities::QueueAgentRunActivity,
          hash_including(count_toward_draft_review_round: true, expected_draft_review_count: 2),
          timeout: anything)
    end

    it "does not start followup when review_goal_retry is combined with only gate triggers" do
      pr_data = {
        issue_id: 10, pr_number: 42, phase: "draft",
        triggers: [
          { type: "review_goal_retry", details: "Retrying failed review-goal run" },
          { type: "paid_agent_review_pending" }
        ],
        current_review_goal_retry_count: 1
      }

      workflow.send(:handle_pr_trigger, project_id, pr_data)

      expect(workflow).to have_received(:run_activity)
        .with(Activities::RecordReviewGoalRetryActivity,
          hash_including(issue_id: 10, expected_review_goal_retry_count: 1), timeout: anything)
      expect(workflow).to have_received(:run_activity)
        .with(Activities::QueueAgentRunActivity,
          hash_including(goal: "review"), timeout: anything)
      expect(workflow).not_to have_received(:run_activity)
        .with(Activities::QueueAgentRunActivity,
          hash_including(:count_toward_draft_review_round), timeout: anything)
    end

    it "dispatches review_bot_review_pending when bundled with review_goal_retry" do
      pr_data = {
        issue_id: 10, pr_number: 42, phase: "draft",
        triggers: [
          { type: "review_goal_retry", details: "Retrying failed review-goal run" },
          { type: "review_bot_review_pending", request_login: "copilot-bot" }
        ],
        current_review_goal_retry_count: 1
      }

      workflow.send(:handle_pr_trigger, project_id, pr_data)

      expect(workflow).to have_received(:run_activity)
        .with(Activities::RecordReviewGoalRetryActivity,
          hash_including(issue_id: 10), timeout: anything)
      expect(workflow).to have_received(:run_activity)
        .with(Activities::QueueAgentRunActivity,
          hash_including(goal: "review"), timeout: anything)
      expect(workflow).to have_received(:run_activity)
        .with(Activities::RequestReviewActivity,
          hash_including(pr_number: 42, reviewers: [ "copilot-bot" ]), timeout: anything)
    end

    it "dispatches manual_review_pending when bundled with review_goal_retry" do
      pr_data = {
        issue_id: 10, pr_number: 42, phase: "draft",
        triggers: [
          { type: "review_goal_retry", details: "Retrying failed review-goal run" },
          { type: "manual_review_pending", reviewer_login: "human-reviewer" }
        ],
        current_review_goal_retry_count: 1
      }

      workflow.send(:handle_pr_trigger, project_id, pr_data)

      expect(workflow).to have_received(:run_activity)
        .with(Activities::RecordReviewGoalRetryActivity,
          hash_including(issue_id: 10), timeout: anything)
      expect(workflow).to have_received(:run_activity)
        .with(Activities::QueueAgentRunActivity,
          hash_including(goal: "review"), timeout: anything)
      expect(workflow).to have_received(:run_activity)
        .with(Activities::RequestReviewActivity,
          hash_including(pr_number: 42, reviewers: [ "human-reviewer" ]), timeout: anything)
    end

    it "dispatches both bot and manual review when bundled with review_goal_retry" do
      pr_data = {
        issue_id: 10, pr_number: 42, phase: "ready",
        triggers: [
          { type: "review_goal_retry", details: "Retrying failed review-goal run" },
          { type: "review_bot_review_pending", request_login: "copilot-bot" },
          { type: "manual_review_pending", reviewer_login: "human-reviewer" }
        ],
        current_review_goal_retry_count: 1
      }

      workflow.send(:handle_pr_trigger, project_id, pr_data)

      expect(workflow).to have_received(:run_activity)
        .with(Activities::QueueAgentRunActivity,
          hash_including(goal: "review"), timeout: anything)
      expect(workflow).to have_received(:run_activity)
        .with(Activities::RequestReviewActivity,
          hash_including(reviewers: [ "copilot-bot" ]), timeout: anything)
      expect(workflow).to have_received(:run_activity)
        .with(Activities::RequestReviewActivity,
          hash_including(reviewers: [ "human-reviewer" ]), timeout: anything)
    end

    it "dispatches bot review and suppresses followup when bot pending coexists with retry followup triggers" do
      pr_data = {
        issue_id: 10, pr_number: 42, phase: "ready",
        triggers: [
          { type: "review_goal_retry", details: "Retrying failed review-goal run" },
          { type: "review_bot_review_pending", request_login: "copilot-bot" },
          { type: "manual_review_pending", reviewer_login: "human-reviewer" },
          { type: "ci_failure", details: [ "rspec" ] }
        ],
        current_review_goal_retry_count: 1
      }

      workflow.send(:handle_pr_trigger, project_id, pr_data)

      expect(workflow).to have_received(:run_activity)
        .with(Activities::QueueAgentRunActivity, hash_including(goal: "review"), timeout: anything)
      expect(workflow).to have_received(:run_activity)
        .with(Activities::RequestReviewActivity, hash_including(reviewers: [ "copilot-bot" ]), timeout: anything)
      expect(workflow).to have_received(:run_activity)
        .with(Activities::RequestReviewActivity, hash_including(reviewers: [ "human-reviewer" ]), timeout: anything)
      expect(workflow).not_to have_received(:run_activity)
        .with(Activities::RecordPrFollowupActivity, anything, timeout: anything)
    end

    it "dispatches bot review and keeps followup when retry includes posted bot feedback" do
      pr_data = {
        issue_id: 10, pr_number: 42, phase: "ready",
        triggers: [
          { type: "review_goal_retry", details: "Retrying failed review-goal run" },
          { type: "review_bot_review_pending", request_login: "copilot-bot" },
          { type: "review_bot_comments", details: [ "Address bot feedback" ] }
        ],
        current_review_goal_retry_count: 1,
        current_followup_count: 0
      }

      workflow.send(:handle_pr_trigger, project_id, pr_data)

      expect(workflow).to have_received(:run_activity)
        .with(Activities::RequestReviewActivity, hash_including(reviewers: [ "copilot-bot" ]), timeout: anything)
      expect(workflow).to have_received(:run_activity)
        .with(Activities::QueueAgentRunActivity, hash_including(goal: "create_pr"), timeout: anything)
      expect(workflow).to have_received(:run_activity)
        .with(Activities::RecordPrFollowupActivity, hash_including(issue_id: 10), timeout: anything)
    end

    it "processes ready_for_owner alongside review_goal_retry" do
      allow(workflow).to receive(:run_activity)
        .with(Activities::MarkPrReadyActivity, anything, timeout: anything)
        .and_return({ marked_ready: true })

      pr_data = {
        issue_id: 10, pr_number: 42, phase: "ready",
        triggers: [
          { type: "review_goal_retry", details: "Retrying failed review-goal run" },
          { type: "ready_for_owner" }
        ],
        current_review_goal_retry_count: 1
      }

      workflow.send(:handle_pr_trigger, project_id, pr_data)

      expect(workflow).to have_received(:run_activity)
        .with(Activities::RecordReviewGoalRetryActivity,
          hash_including(issue_id: 10, expected_review_goal_retry_count: 1), timeout: anything)
      expect(workflow).to have_received(:run_activity)
        .with(Activities::QueueAgentRunActivity,
          hash_including(goal: "review"), timeout: anything)
      expect(workflow).to have_received(:run_activity)
        .with(Activities::MarkPrReadyActivity, anything, timeout: anything)
    end

    it "does not queue duplicate review when paid_agent_review_pending is bundled with review_goal_retry and ready_for_owner" do
      allow(workflow).to receive(:run_activity)
        .with(Activities::MarkPrReadyActivity, anything, timeout: anything)
        .and_return({ marked_ready: true })

      pr_data = {
        issue_id: 10, pr_number: 42, phase: "ready",
        triggers: [
          { type: "review_goal_retry", details: "Retrying failed review-goal run" },
          { type: "ready_for_owner" },
          { type: "paid_agent_review_pending" }
        ],
        current_review_goal_retry_count: 1
      }

      workflow.send(:handle_pr_trigger, project_id, pr_data)

      expect(workflow).to have_received(:run_activity)
        .with(Activities::QueueAgentRunActivity, hash_including(goal: "review"), timeout: anything)
        .once
      expect(workflow).to have_received(:run_activity)
        .with(Activities::MarkPrReadyActivity, anything, timeout: anything)
    end

    it "skips retry queueing when owner_approved will merge the PR" do
      allow(workflow).to receive(:run_activity)
        .with(Activities::MergePullRequestActivity, anything, timeout: anything)
        .and_return({ merged: true })
      allow(Temporalio::Workflow).to receive(:patched).and_call_original
      allow(Temporalio::Workflow).to receive(:patched)
        .with("add-dev-environment-update-v1").and_return(false)

      pr_data = {
        issue_id: 10, pr_number: 42, phase: "ready",
        triggers: [ { type: "review_goal_retry" }, { type: "owner_approved" } ],
        current_review_goal_retry_count: 1
      }

      workflow.send(:handle_pr_trigger, project_id, pr_data)

      expect(workflow).not_to have_received(:run_activity)
        .with(Activities::RecordReviewGoalRetryActivity, anything, timeout: anything)
      expect(workflow).to have_received(:run_activity)
        .with(Activities::MergePullRequestActivity, anything, timeout: anything)
    end

    it "skips owner review request when owner_reviewer_login is blank" do
      allow(workflow).to receive(:run_activity)
        .with(Activities::MarkPrReadyActivity, anything, timeout: anything)
        .and_return({ marked_ready: true })

      pr_data = {
        issue_id: 10, pr_number: 42, owner_reviewer_login: nil,
        triggers: [ { type: "ready_for_owner" } ]
      }

      workflow.send(:handle_pr_trigger, project_id, pr_data)

      expect(workflow).to have_received(:run_activity)
        .with(Activities::MarkPrReadyActivity, anything, timeout: anything)
      expect(workflow).not_to have_received(:run_activity)
        .with(Activities::RequestReviewActivity, anything, timeout: anything)
    end

    it "routes paid_agent_review_pending to QueueAgentRunActivity with review goal" do
      pr_data = {
        issue_id: 10, pr_number: 42,
        triggers: [ { type: "paid_agent_review_pending" } ]
      }

      workflow.send(:handle_pr_trigger, project_id, pr_data)

      expect(workflow).to have_received(:run_activity)
        .with(Activities::QueueAgentRunActivity,
          hash_including(project_id: 1, issue_id: 10,
            source_pull_request_number: 42, goal: "review"),
          timeout: anything)
    end

    it "suppresses create_pr followup when paid_agent_review_pending coexists with other triggers (#1135)" do
      allow(workflow).to receive(:run_activity).with(Activities::QueueAgentRunActivity, anything, timeout: anything)
        .and_return({ queued: true })

      pr_data = draft_pr_data(
        current_draft_review_count: 0,
        triggers: [
          { type: "paid_agent_review_pending" },
          { type: "ci_failure", details: "CI failed" }
        ]
      )

      workflow.send(:handle_pr_trigger, project_id, pr_data)

      expect(workflow).to have_received(:run_activity).with(
        Activities::QueueAgentRunActivity,
        expected_review_queue_input,
        timeout: anything
      )
      expect(workflow).not_to have_received(:run_activity).with(
        Activities::QueueAgentRunActivity,
        hash_including(goal: "create_pr"),
        timeout: anything
      )
    end

    it "suppresses create_pr followup for ready-phase PRs when paid_agent review is pending (#1135)" do
      allow(workflow).to receive(:run_activity)
        .with(Activities::QueueAgentRunActivity, anything, timeout: anything).and_return({ queued: true })

      pr_data = {
        issue_id: 10, pr_number: 42, phase: "ready", current_followup_count: 0,
        triggers: [
          { type: "paid_agent_review_pending" },
          { type: "merge_conflicts", details: "PR has merge conflicts" }
        ]
      }

      workflow.send(:handle_pr_trigger, project_id, pr_data)

      expect(workflow).to have_received(:run_activity)
        .with(Activities::QueueAgentRunActivity, expected_review_queue_input, timeout: anything)
      expect(workflow).not_to have_received(:run_activity)
        .with(Activities::QueueAgentRunActivity, hash_including(goal: "create_pr"), timeout: anything)
      expect(workflow).not_to have_received(:run_activity)
        .with(Activities::RecordPrFollowupActivity, anything, timeout: anything)
    end

    it "suppresses create_pr followup when paid_agent review has active_run and other triggers present (#1135)" do
      allow(workflow).to receive(:run_activity).with(Activities::QueueAgentRunActivity, anything, timeout: anything)
        .and_return({ queued: true })

      pr_data = draft_pr_data(
        current_draft_review_count: 1,
        triggers: [
          { type: "paid_agent_review_pending", active_run: true },
          { type: "conversation_comments", details: "2 new comment(s)" }
        ]
      )

      workflow.send(:handle_pr_trigger, project_id, pr_data)

      expect(workflow).not_to have_received(:run_activity).with(
        Activities::QueueAgentRunActivity, hash_including(goal: "review"), timeout: anything
      )
      expect(workflow).not_to have_received(:run_activity).with(
        Activities::QueueAgentRunActivity, hash_including(goal: "create_pr"), timeout: anything
      )
    end

    it "falls back to old behavior before pause-followup-during-review-v1 patch" do
      allow(Temporalio::Workflow).to receive(:patched)
        .with("pause-followup-during-review-v1")
        .and_return(false)
      allow(workflow).to receive(:run_activity).with(Activities::QueueAgentRunActivity, anything, timeout: anything)
        .and_return({ queued: true })

      pr_data = draft_pr_data(
        current_draft_review_count: 0,
        triggers: [
          { type: "paid_agent_review_pending" },
          { type: "ci_failure", details: "CI failed" }
        ]
      )

      workflow.send(:handle_pr_trigger, project_id, pr_data)

      expect(workflow).to have_received(:run_activity).with(
        Activities::QueueAgentRunActivity,
        hash_including(count_toward_draft_review_round: true, expected_draft_review_count: 0),
        timeout: anything
      )
    end

    it "does not queue a duplicate paid_agent review when the trigger reflects an active run" do
      allow(workflow).to receive(:run_activity)
        .with(Activities::QueueAgentRunActivity, anything, timeout: anything)
        .and_return({ queued: true })

      pr_data = {
        issue_id: 10, pr_number: 42,
        triggers: [ { type: "paid_agent_review_pending", active_run: true } ]
      }

      workflow.send(:handle_pr_trigger, project_id, pr_data)

      expect(workflow).not_to have_received(:run_activity)
        .with(Activities::QueueAgentRunActivity, hash_including(goal: "review"), timeout: anything)
    end

    it "skips paid_agent review queueing before the Temporal patch" do
      allow(Temporalio::Workflow).to receive(:patched).and_call_original
      allow(Temporalio::Workflow).to receive(:patched)
        .with("queue-paid-agent-review-run-v1")
        .and_return(false)
      allow(Temporalio::Workflow).to receive(:patched)
        .with("pause-followup-during-review-v1")
        .and_return(true)

      pr_data = {
        issue_id: 10, pr_number: 42,
        triggers: [ { type: "paid_agent_review_pending" } ]
      }

      workflow.send(:handle_pr_trigger, project_id, pr_data)

      expect(workflow).not_to have_received(:run_activity)
        .with(Activities::QueueAgentRunActivity, hash_including(goal: "review"), timeout: anything)
    end
  end

  describe "#quality_gate_allows_run?" do
    let(:project_id) { 1 }

    before do
      allow(workflow).to receive(:quality_gate_allows_run?).and_call_original
      allow(Temporalio::Workflow).to receive_messages(logger: Rails.logger)
    end

    it "allows queueing without running the quality gate activity before the Temporal patch" do
      allow(Temporalio::Workflow).to receive(:patched)
        .with("github-poll-quality-gate-v1")
        .and_return(false)
      allow(workflow).to receive(:run_activity)

      result = workflow.send(:quality_gate_allows_run?, project_id, { issue_id: 10 }, goal: "create_pr")

      expect(result).to be(true)
      expect(workflow).not_to have_received(:run_activity)
        .with(Activities::CheckQualityGateActivity, anything, timeout: anything)
    end

    it "runs the quality gate activity after the Temporal patch" do
      allow(Temporalio::Workflow).to receive(:patched)
        .with("github-poll-quality-gate-v1")
        .and_return(true)
      allow(workflow).to receive(:run_activity)
        .with(Activities::CheckQualityGateActivity, anything, timeout: anything)
        .and_return({ allowed: false, reason: "quality_gate_breached", breaches: [ { metric: "composite_score" } ] })

      result = workflow.send(:quality_gate_allows_run?, project_id, { issue_id: 10 }, goal: "create_pr")

      expect(result).to be(false)
      expect(workflow).to have_received(:run_activity)
        .with(Activities::CheckQualityGateActivity, hash_including(issue_id: 10, goal: "create_pr"), timeout: 30)
    end
  end

  describe "#evaluate_issues_batch" do
    let(:workflow) { described_class.new }
    let(:project_id) { 1 }

    before do
      allow(workflow).to receive(:run_activity).and_return({})
      allow(Temporalio::Workflow).to receive(:patched)
        .with("queue-agent-run-goal-v1")
        .and_return(true)
    end

    it "calls EvaluateIssuesActivity with all issue IDs" do
      allow(workflow).to receive(:run_activity)
        .with(Activities::EvaluateIssuesActivity, anything, timeout: anything)
        .and_return({ results: [] })

      issues = [ { id: 10 }, { id: 20 }, { id: 30 } ]
      workflow.send(:evaluate_issues_batch, project_id, issues)

      expect(workflow).to have_received(:run_activity)
        .with(Activities::EvaluateIssuesActivity,
          { project_id: project_id, issue_ids: [ 10, 20, 30 ] }, timeout: 120)
    end

    it "dispatches each result through handle_automation_result" do
      allow(workflow).to receive(:run_activity)
        .with(Activities::EvaluateIssuesActivity, anything, timeout: anything)
        .and_return({
          results: [
            { decisions: [ { type: "queue_create_pr_run", issue_id: 10 } ] },
            { decisions: [ { type: "noop" } ] }
          ]
        })
      allow(workflow).to receive(:run_activity)
        .with(Activities::QueueAgentRunActivity, anything, timeout: anything)
        .and_return({ queued: true })

      workflow.send(:evaluate_issues_batch, project_id, [ { id: 10 }, { id: 20 } ])

      expect(workflow).to have_received(:run_activity)
        .with(Activities::QueueAgentRunActivity,
          { project_id: project_id, issue_id: 10, goal: "create_pr" }, timeout: 30)
    end

    it "skips when issues list is empty" do
      workflow.send(:evaluate_issues_batch, project_id, [])

      expect(workflow).not_to have_received(:run_activity)
        .with(Activities::EvaluateIssuesActivity, anything, timeout: anything)
    end

    it "handles nil results gracefully" do
      allow(workflow).to receive(:run_activity)
        .with(Activities::EvaluateIssuesActivity, anything, timeout: anything)
        .and_return({ results: nil })

      expect { workflow.send(:evaluate_issues_batch, project_id, [ { id: 10 } ]) }
        .not_to raise_error
    end
  end

  describe "batch-evaluate-issues-v1 patch guard" do
    let(:workflow) { described_class.new }
    let(:project_id) { 1 }

    before do
      allow(workflow).to receive(:run_activity).and_return({})
      allow(Temporalio::Workflow).to receive(:patched)
        .with("queue-agent-run-goal-v1")
        .and_return(true)
    end

    it "uses EvaluateIssuesActivity when patched" do
      allow(Temporalio::Workflow).to receive(:patched)
        .with("batch-evaluate-issues-v1")
        .and_return(true)
      allow(workflow).to receive(:run_activity)
        .with(Activities::EvaluateIssuesActivity, anything, timeout: anything)
        .and_return({ results: [] })

      workflow.send(:evaluate_issues_batch, project_id, [ { id: 10 } ])

      expect(workflow).to have_received(:run_activity)
        .with(Activities::EvaluateIssuesActivity, anything, timeout: anything)
    end
  end

  describe "initial sync for existing PRs" do
    let(:workflow) { described_class.new }
    let(:project_id) { 1 }

    def stub_initial_sync(trigger_result:)
      allow(workflow).to receive(:run_activity)
        .with(Activities::FetchIssuesActivity, { project_id: project_id }, timeout: 60)
        .and_return(
          { issues: [ { id: 10 } ], project_id: project_id },
          { issues: [], project_id: project_id, project_missing: true }
        )
      allow(workflow).to receive(:run_activity)
        .with(Activities::DetectLabelsActivity, { project_id: project_id, issue_id: 10 }, timeout: 30)
        .and_return({ decisions: [ { type: "noop" } ], action: "none", issue_id: 10, project_id: project_id })
      allow(workflow).to receive(:run_activity)
        .with(Activities::ScanPaidPrsActivity, { project_id: project_id }, timeout: 120)
        .and_return(trigger_result)
      allow(workflow).to receive(:run_activity)
        .with(Activities::QueueAgentRunActivity, anything, timeout: anything)
        .and_return({ queued: true })
    end

    def execute_initial_sync(trigger_result:)
      stub_initial_sync(trigger_result: trigger_result)
      workflow.execute(project_id: project_id)
    end

    before do
      allow(Temporalio::Workflow).to receive(:continue_as_new_suggested).and_return(false)
      allow(Temporalio::Workflow).to receive(:patched).and_call_original
      allow(Temporalio::Workflow).to receive(:patched)
        .with("add-rate-limit-budget-v1").and_return(false)
      allow(Temporalio::Workflow).to receive(:patched)
        .with("add-scan-paid-prs-v1").and_return(true)
      allow(Temporalio::Workflow).to receive(:patched)
        .with("add-scan-security-alerts-v1").and_return(false)
      allow(Temporalio::Workflow).to receive(:patched)
        .with("add-check-knowledge-staleness-v1").and_return(false)
      allow(Temporalio::Workflow).to receive(:patched)
        .with("add-auto-release-poll-v1").and_return(false)
      allow(Temporalio::Workflow).to receive(:patched)
        .with("queue-agent-run-goal-v1").and_return(true)
      allow(Temporalio::Workflow).to receive(:patched)
        .with("queue-paid-agent-review-run-v1").and_return(true)
      allow(Temporalio::Workflow).to receive(:patched)
        .with("pause-followup-during-review-v1").and_return(true)
      allow(Temporalio::Workflow).to receive(:patched)
        .with("pause-review-bot-followup-during-review-v1").and_return(true)
      allow(Temporalio::Workflow).to receive(:patched)
        .with("batch-evaluate-issues-v1").and_return(true)
      allow(Temporalio::Workflow).to receive(:patched)
        .with("notification-rules-v1").and_return(false)
      allow(workflow).to receive(:interruptible_sleep)
      allow(workflow).to receive(:with_jitter) { |base| base }
      allow(workflow).to receive(:run_activity)
        .with(Activities::GetPollIntervalActivity, anything, timeout: anything)
        .and_return({ poll_interval_seconds: 60 })
      allow(workflow).to receive(:run_activity)
        .with(Activities::RecordPollHeartbeatActivity, anything, timeout: anything)
        .and_return({ recorded: true })
      allow(workflow).to receive(:run_activity)
        .with(Activities::LoadFeatureFlagsActivity, { project_id: project_id }, timeout: 10)
        .and_return(flags: { explicit_pr_automation_decisions: false }, project_missing: false)
      allow(workflow).to receive(:run_activity)
        .with(Activities::EvaluateIssuesActivity, anything, timeout: anything)
        .and_return({ results: [ { decisions: [ { type: "noop" } ], action: "none", issue_id: 10, project_id: project_id } ] })
    end

    it "queues a review run when paid_agent_review_pending is the only initial-sync PR signal" do
      execute_initial_sync(trigger_result: {
        prs_to_trigger: [
          {
            issue_id: 10,
            pr_number: 42,
            phase: "ready",
            triggers: [ { type: "paid_agent_review_pending" } ]
          }
        ]
      })

      expect(workflow).to have_received(:run_activity)
        .with(Activities::QueueAgentRunActivity,
          hash_including(project_id: project_id, issue_id: 10,
            source_pull_request_number: 42, goal: "review"),
          timeout: 30)
      expect(workflow).not_to have_received(:run_activity)
        .with(Activities::QueueAgentRunActivity,
          hash_including(project_id: project_id, issue_id: 10,
            source_pull_request_number: 42, goal: "create_pr"),
          timeout: 30)
    end

    it "does not queue a create_pr run when an existing PR has no actionable initial-sync followup" do
      execute_initial_sync(trigger_result: { prs_to_trigger: [] })

      expect(workflow).not_to have_received(:run_activity)
        .with(Activities::QueueAgentRunActivity,
          hash_including(project_id: project_id, issue_id: 10,
            source_pull_request_number: 42, goal: "create_pr"),
          timeout: 30)
    end

    it "executes flagged explicit PR automation decisions instead of legacy trigger translation" do
      allow(workflow).to receive(:run_activity)
        .with(Activities::LoadFeatureFlagsActivity, { project_id: project_id }, timeout: 10)
        .and_return(flags: { explicit_pr_automation_decisions: true }, project_missing: false)

      execute_initial_sync(trigger_result: {
        prs_to_trigger: [],
        automation_results: [
          {
            decisions: [
              { type: "queue_review_run", issue_id: 10, source_pull_request_number: 42 }
            ]
          }
        ]
      })

      expect(workflow).to have_received(:run_activity)
        .with(Activities::QueueAgentRunActivity,
          hash_including(project_id: project_id, issue_id: 10,
            source_pull_request_number: 42, goal: "review"),
          timeout: 30)
    end
  end

  # Regression coverage for PR #1077: the full poll cycle must never implicitly
  # queue a default create_pr run for an existing automation-labeled PR. These
  # end-to-end workflow tests lock the decision boundary between initial sync
  # (DetectLabelsActivity) and PR follow-up (ScanPaidPrsActivity) and assert
  # that every PR-targeting QueueAgentRunActivity call carries an explicit goal.
  describe "#1077 regression: PR-originated queue paths require explicit goals" do
    let(:workflow) { described_class.new }
    let(:project_id) { 1 }

    before do
      allow(Temporalio::Workflow).to receive(:start_child_workflow)
      allow(Temporalio::Workflow).to receive(:patched).and_call_original
      allow(Temporalio::Workflow).to receive(:patched)
        .with("draft-followup-direct-start-v1").and_return(true)
      allow(Temporalio::Workflow).to receive(:patched)
        .with("queue-agent-run-goal-v1").and_return(true)
      allow(Temporalio::Workflow).to receive(:patched)
        .with("queue-paid-agent-review-run-v1").and_return(true)
      allow(Temporalio::Workflow).to receive(:patched)
        .with("pause-followup-during-review-v1").and_return(true)
      allow(Temporalio::Workflow).to receive(:patched)
        .with("pause-review-bot-followup-during-review-v1").and_return(true)
      allow(workflow).to receive(:run_activity).and_return({})
    end

    it "routes draft-phase paid_agent_review_pending to a review run with no create_pr side effect" do
      pr_data = {
        issue_id: 10, pr_number: 42, phase: "draft",
        current_draft_review_count: 0,
        triggers: [ { type: "paid_agent_review_pending" } ]
      }

      workflow.send(:handle_pr_trigger, project_id, pr_data)

      expect(workflow).to have_received(:run_activity)
        .with(Activities::QueueAgentRunActivity,
          hash_including(goal: "review", source_pull_request_number: 42), timeout: anything)
      expect(workflow).not_to have_received(:run_activity)
        .with(Activities::QueueAgentRunActivity, hash_including(goal: "create_pr"), timeout: anything)
    end

    it "queues no runs when an initial PR scan returns no actionable triggers" do
      allow(workflow).to receive(:run_activity).and_return({ prs_to_trigger: [] })

      workflow.send(:handle_pr_scan_results, { prs_to_trigger: [] }, project_id)

      expect(workflow).not_to have_received(:run_activity)
        .with(Activities::QueueAgentRunActivity, anything, timeout: anything)
    end

    it "queues draft create_pr with explicit goal when a follow-up scan reports CI failure" do
      allow(workflow).to receive(:run_activity)
        .with(Activities::QueueAgentRunActivity, anything, timeout: anything)
        .and_return({ queued: true })

      pr_data = {
        issue_id: 10, pr_number: 42, phase: "draft",
        current_draft_review_count: 0,
        triggers: [ { type: "ci_failure", details: [ "rspec" ] } ]
      }

      workflow.send(:handle_pr_trigger, project_id, pr_data)

      expect(workflow).to have_received(:run_activity)
        .with(Activities::QueueAgentRunActivity,
          hash_including(
            project_id: project_id,
            issue_id: 10,
            source_pull_request_number: 42,
            goal: "create_pr",
            count_toward_draft_review_round: true,
            expected_draft_review_count: 0
          ), timeout: 30)
    end

    it "queues ready-phase create_pr with explicit goal on merge_conflicts + conversation_comments" do
      allow(workflow).to receive(:run_activity)
        .with(Activities::QueueAgentRunActivity, anything, timeout: anything)
        .and_return({ queued: true })
      pr_data = {
        issue_id: 10, pr_number: 42, phase: "ready", current_followup_count: 0,
        triggers: [
          { type: "merge_conflicts", details: "PR has merge conflicts" },
          { type: "conversation_comments", details: "2 new comment(s)" }
        ]
      }

      workflow.send(:handle_pr_trigger, project_id, pr_data)

      expect(workflow).to have_received(:run_activity)
        .with(Activities::QueueAgentRunActivity,
          hash_including(project_id: project_id, issue_id: 10,
            source_pull_request_number: 42, goal: "create_pr"), timeout: 30)
      expect(workflow).to have_received(:run_activity)
        .with(Activities::RecordPrFollowupActivity, anything, timeout: anything)
    end

    def record_queue_invocations(workflow)
      collected = []
      allow(workflow).to receive(:run_activity) do |activity_class, input, **_opts|
        collected << input if activity_class == Activities::QueueAgentRunActivity
        case activity_class
        when Activities::MarkPrReadyActivity then { marked_ready: true }
        when Activities::QueueAgentRunActivity then { queued: true }
        else {}
        end
      end
      collected
    end

    def pr_scenarios_requiring_explicit_goal
      # Each scenario must exercise a code path that ends up calling
      # QueueAgentRunActivity with a source_pull_request_number, so the
      # guardrail below can assert an explicit :goal is always set.
      [
        { phase: "draft", current_draft_review_count: 0, triggers: [ { type: "ci_failure" } ] },
        { phase: "draft", current_draft_review_count: 0, triggers: [ { type: "paid_agent_review_pending" } ] },
        { phase: "ready", current_followup_count: 0, triggers: [ { type: "merge_conflicts" } ] },
        { phase: "ready", current_review_goal_retry_count: 0,
          triggers: [ { type: "review_goal_retry", details: "retry" } ] }
      ]
    end

    it "never calls QueueAgentRunActivity with a PR number and no goal across PR trigger types" do
      queue_invocations = record_queue_invocations(workflow)

      pr_scenarios_requiring_explicit_goal.each do |scenario|
        workflow.send(:handle_pr_trigger, project_id, scenario.merge(issue_id: 10, pr_number: 42))
      end

      pr_targeting_calls = queue_invocations.select do |input|
        input.is_a?(Hash) && input[:source_pull_request_number].present?
      end
      offending = pr_targeting_calls.select { |input| input[:goal].blank? }

      expect(offending).to be_empty, "expected every PR-targeting QueueAgentRunActivity call to carry an explicit :goal"
      expect(pr_targeting_calls).not_to be_empty, "scenarios must actually exercise PR queueing paths"
    end
  end
end
