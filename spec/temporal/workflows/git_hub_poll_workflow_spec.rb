# frozen_string_literal: true

require "rails_helper"

RSpec.describe Workflows::GitHubPollWorkflow do
  let(:workflow) { described_class.new }

  before do
    allow(workflow).to receive(:quality_gate_allows_run?).and_return(true)
  end

  def stub_planning_workflow_start(workflow)
    allow(workflow).to receive(:run_activity)
      .with(Activities::LoadFeatureFlagsActivity, anything, timeout: anything)
      .and_return({ flags: {} })
    allow(workflow).to receive(:run_activity)
      .with(Activities::CheckRunCapacityActivity, anything, timeout: anything)
      .and_return({ has_capacity: true })
    allow(Temporalio::Workflow).to receive(:now).and_return(Time.now)
  end

  def exhausted_activity_error(activity_type)
    Temporalio::Error::ActivityError.new(
      "activity failed",
      scheduled_event_id: 1,
      started_event_id: 2,
      identity: "worker-1",
      activity_type: activity_type,
      activity_id: "activity-1",
      retry_state: Temporalio::Error::RetryState::MAXIMUM_ATTEMPTS_REACHED
    )
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
    it "registers request_sync as a Temporal signal" do
      # Temporal stores declared workflow_signal handlers on the class as they
      # are defined. Inspecting that registry avoids forcing lazy definition
      # construction, which is brittle in the current gem load order.
      signal_names = (described_class.instance_variable_get(:@workflow_signals) || {}).keys.map(&:to_s)

      expect(signal_names).to include("request_sync")
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

  describe "#execute_automation_decision" do
    let(:project_id) { 1 }
    let(:logger) { instance_double(Logger, warn: nil) }

    before do
      allow(workflow).to receive(:run_activity)
      allow(workflow).to receive(:quality_gate_allows_run?).and_return(true)
      allow(Temporalio::Workflow).to receive(:logger).and_return(logger)
    end

    it "routes dispatch_claude_review decisions to DispatchClaudeReviewActivity" do
      workflow.execute_automation_decision(
        project_id:,
        decision: { type: "dispatch_claude_review", pr_number: 42 }
      )

      expect(workflow).to have_received(:run_activity).with(
        Activities::DispatchClaudeReviewActivity,
        { project_id:, pr_number: 42 },
        timeout: 60
      )
    end

    it "routes request_review decisions to RequestReviewActivity" do
      workflow.execute_automation_decision(
        project_id:,
        decision: { type: "request_review", pr_number: 42, reviewers: [ "viamin" ] }
      )

      expect(workflow).to have_received(:run_activity).with(
        Activities::RequestReviewActivity,
        { project_id:, pr_number: 42, reviewers: [ "viamin" ] },
        timeout: 60
      )
    end

    # @spec AUTO-MERGE-007
    it "stamps owner_review_requested_sha when the request_review decision carries issue_id and head_sha" do
      allow(workflow).to receive(:run_activity)
        .with(
          Activities::RequestReviewActivity,
          { project_id:, pr_number: 42, reviewers: [ "viamin" ] },
          timeout: 60
        )
        .and_return({ requested: [ "viamin" ] })

      workflow.execute_automation_decision(
        project_id:,
        decision: {
          type: "request_review", pr_number: 42, reviewers: [ "viamin" ],
          issue_id: 7, head_sha: "abc123"
        }
      )

      expect(workflow).to have_received(:run_activity).with(
        Activities::RecordOwnerReviewRequestActivity,
        { issue_id: 7, head_sha: "abc123" },
        timeout: 30
      )
    end

    it "stamps owner_review_requested_sha when the owner review request is already pending" do
      allow(workflow).to receive(:run_activity)
        .with(
          Activities::RequestReviewActivity,
          { project_id:, pr_number: 42, reviewers: [ "viamin" ] },
          timeout: 60
        )
        .and_return({ requested: [], already_pending: [ "viamin" ] })

      workflow.execute_automation_decision(
        project_id:,
        decision: {
          type: "request_review", pr_number: 42, reviewers: [ "viamin" ],
          issue_id: 7, head_sha: "abc123"
        }
      )

      expect(workflow).to have_received(:run_activity).with(
        Activities::RecordOwnerReviewRequestActivity,
        { issue_id: 7, head_sha: "abc123" },
        timeout: 30
      )
    end

    it "does not stamp owner_review_requested_sha when request_review fails transiently" do
      error = exhausted_activity_error("RequestReviewActivity")
      allow(workflow).to receive(:run_activity)
        .with(
          Activities::RequestReviewActivity,
          { project_id:, pr_number: 42, reviewers: [ "viamin" ] },
          timeout: 60
        )
        .and_raise(error)
      allow(workflow).to receive(:record_swallowed_non_critical_activity_failure)

      workflow.execute_automation_decision(
        project_id:,
        decision: {
          type: "request_review", pr_number: 42, reviewers: [ "viamin" ],
          issue_id: 7, head_sha: "abc123"
        }
      )

      expect(workflow).not_to have_received(:run_activity).with(
        Activities::RecordOwnerReviewRequestActivity, anything, anything
      )
    end

    it "does not stamp owner_review_requested_sha when request_review returns a handled 422 no-op" do
      allow(workflow).to receive(:run_activity)
        .with(
          Activities::RequestReviewActivity,
          { project_id:, pr_number: 42, reviewers: [ "viamin" ] },
          timeout: 60
        )
        .and_return({ requested: [], error: "Review cannot be requested" })

      workflow.execute_automation_decision(
        project_id:,
        decision: {
          type: "request_review", pr_number: 42, reviewers: [ "viamin" ],
          issue_id: 7, head_sha: "abc123"
        }
      )

      expect(workflow).not_to have_received(:run_activity).with(
        Activities::RecordOwnerReviewRequestActivity, anything, anything
      )
    end

    it "does not stamp owner_review_requested_sha when the request_review decision omits issue_id/head_sha" do
      workflow.execute_automation_decision(
        project_id:,
        decision: { type: "request_review", pr_number: 42, reviewers: [ "copilot" ] }
      )

      expect(workflow).not_to have_received(:run_activity).with(
        Activities::RecordOwnerReviewRequestActivity, anything, anything
      )
    end

    it "warns when a decision type is not implemented" do
      logger = instance_double(Logger, warn: true)
      allow(Temporalio::Workflow).to receive(:logger).and_return(logger)

      workflow.execute_automation_decision(
        project_id:,
        decision: { type: "future_decision_type" }
      )

      expect(logger).to have_received(:warn).with(
        message: "workflow_decision_executor.unknown_decision_type",
        project_id: project_id,
        type: "future_decision_type"
      )
    end
  end

  describe "#maybe_scan_paid_prs" do
    let(:workflow) { described_class.new }
    let(:logger) { instance_double(Logger, warn: nil) }

    before do
      allow(workflow).to receive(:run_activity).and_return({ automation_results: [] })
      allow(Temporalio::Workflow).to receive_messages(logger: logger, patched: true)
    end

    def activity_error_with_cause(cause)
      begin
        begin
          raise cause
        rescue
          raise Temporalio::Error::ActivityError.new(
            "activity failed",
            scheduled_event_id: 1, started_event_id: 2, identity: "",
            activity_type: "ScanPaidPrs", activity_id: "1",
            retry_state: Temporalio::Error::RetryState::NON_RETRYABLE_FAILURE
          )
        end
      rescue => e
        e
      end
    end

    it "runs ScanPaidPrsActivity, executes decisions, and returns the scan result" do
      allow(workflow).to receive(:handle_pr_scan_results)

      result = workflow.send(:maybe_scan_paid_prs, 1)

      expect(workflow).to have_received(:run_activity)
        .with(Activities::ScanPaidPrsActivity, { project_id: 1 }, timeout: 300, heartbeat_timeout: described_class::DEFAULT_HEARTBEAT_TIMEOUT)
      expect(workflow).to have_received(:handle_pr_scan_results).with({ automation_results: [] }, 1)
      expect(result).to eq({ automation_results: [] })
    end

    it "swallows scan activity errors so the poll loop survives" do
      allow(workflow).to receive(:run_activity)
        .with(Activities::ScanPaidPrsActivity, anything, timeout: anything, heartbeat_timeout: anything)
        .and_raise(StandardError.new("provider factory crash"))
      allow(workflow).to receive(:record_swallowed_non_critical_activity_failure)

      result = workflow.send(:maybe_scan_paid_prs, 1)

      expect(result).to be_nil
      expect(workflow).to have_received(:record_swallowed_non_critical_activity_failure).with(
        project_id: 1,
        helper: "maybe_scan_paid_prs",
        error: kind_of(StandardError)
      )
      expect(logger).to have_received(:warn).with(hash_including(
        message: "pr_scanner.scan_failed",
        project_id: 1
      ))
    end

    it "does not swallow errors from handle_pr_scan_results (automation decisions must propagate)" do
      allow(workflow).to receive(:handle_pr_scan_results)
        .and_raise(StandardError, "decision execution failure")

      expect { workflow.send(:maybe_scan_paid_prs, 1) }
        .to raise_error(StandardError, /decision execution failure/)
    end

    it "re-raises CanceledError so workflow shutdown is not delayed" do
      allow(workflow).to receive(:run_activity)
        .with(Activities::ScanPaidPrsActivity, anything, timeout: anything, heartbeat_timeout: anything)
        .and_raise(Temporalio::Error::CanceledError.new("cancelled"))

      expect { workflow.send(:maybe_scan_paid_prs, 1) }
        .to raise_error(Temporalio::Error::CanceledError)
    end

    it "re-raises AuthError activity failures so stale credentials fail loudly" do
      auth_error = Temporalio::Error::ApplicationError.new(
        "GitHub authentication failed",
        type: "AuthError"
      )
      activity_error = activity_error_with_cause(auth_error)
      allow(workflow).to receive(:run_activity)
        .with(Activities::ScanPaidPrsActivity, anything, timeout: anything, heartbeat_timeout: anything)
        .and_raise(activity_error)

      expect { workflow.send(:maybe_scan_paid_prs, 1) }
        .to raise_error(Temporalio::Error::ActivityError)
    end
  end

  describe "notification rule evaluation" do
    let(:workflow) { described_class.new }

    before do
      allow(workflow).to receive(:run_activity)
    end

    it "runs EvaluateNotificationRulesActivity with fetched issue ids and PR scan context" do
      workflow.send(:run_notification_rules, 1,
        issue_ids: [ 10, 11 ],
        pr_scan_result: {
          pr_issue_ids: [ 11 ],
          pending_review_states: [ { issue_id: 11, pending_review: true, requested_bot: "copilot", pr_phase: "draft" } ],
          pr_progress_states: [ { issue_id: 11, consecutive_unsuccessful_automatic_runs: 2 } ]
        })

      expect(workflow).to have_received(:run_activity).with(
        Activities::EvaluateNotificationRulesActivity,
        {
          project_id: 1,
          issue_ids: [ 10, 11 ],
          pr_issue_ids: [ 11 ],
          pending_review_states: [ { issue_id: 11, pending_review: true, requested_bot: "copilot", pr_phase: "draft" } ],
          pr_progress_states: [ { issue_id: 11, consecutive_unsuccessful_automatic_runs: 2 } ]
        },
        timeout: 60
      )
    end

    it "forwards string-keyed PR scan payloads from serialized activity results" do
      workflow.send(:run_notification_rules, 1,
        issue_ids: [ 10, 11 ],
        pr_scan_result: {
          "pr_issue_ids" => [ 11 ],
          "pending_review_states" => [ { "issue_id" => "11", "pending_review" => true } ],
          "pr_progress_states" => [ { "issue_id" => "11", "consecutive_unsuccessful_automatic_runs" => 2 } ]
        })

      expect(workflow).to have_received(:run_activity).with(
        Activities::EvaluateNotificationRulesActivity,
        {
          project_id: 1,
          issue_ids: [ 10, 11 ],
          pr_issue_ids: [ 11 ],
          pending_review_states: [ { "issue_id" => "11", "pending_review" => true } ],
          pr_progress_states: [ { "issue_id" => "11", "consecutive_unsuccessful_automatic_runs" => 2 } ]
        },
        timeout: 60
      )
    end
  end

  describe "rate limit budget coordination" do
    let(:workflow) { described_class.new }

    before do
      allow(workflow).to receive(:run_activity).and_return({})
      allow(workflow).to receive(:maybe_scan_code_scanning_alerts)
      allow(workflow).to receive(:maybe_check_knowledge_staleness)
      allow(workflow).to receive(:maybe_evaluate_auto_release)
      allow(workflow).to receive(:maybe_evaluate_dependabot_auto_merge)
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
        .and_return({ automation_results: [] })

      workflow.send(:maybe_run_non_critical_activities, 1)

      expect(workflow).to have_received(:run_activity)
        .with(Activities::ScanPaidPrsActivity, { project_id: 1 }, timeout: 300, heartbeat_timeout: described_class::DEFAULT_HEARTBEAT_TIMEOUT)
    end

    it "runs the rate limit check before the non-critical activities" do
      allow(workflow).to receive(:run_activity)
        .with(Activities::CheckRateLimitActivity, anything, timeout: anything)
        .and_return({ rate_limit_remaining: 500, rate_limit_low: false })
      allow(workflow).to receive(:run_activity)
        .with(Activities::ScanPaidPrsActivity, anything, timeout: anything)
        .and_return({ automation_results: [] })

      workflow.send(:maybe_run_non_critical_activities, 1)

      expect(workflow).to have_received(:run_activity)
        .with(Activities::CheckRateLimitActivity, { project_id: 1 }, timeout: 10)
      expect(workflow).to have_received(:run_activity)
        .with(Activities::ScanPaidPrsActivity, { project_id: 1 }, timeout: 300, heartbeat_timeout: described_class::DEFAULT_HEARTBEAT_TIMEOUT)
    end
  end

  describe "#maybe_check_knowledge_staleness" do
    let(:workflow) { described_class.new }

    before do
      allow(workflow).to receive(:run_activity).and_return({})
    end

    it "runs CheckKnowledgeStalenessActivity" do
      workflow.send(:maybe_check_knowledge_staleness, 1)

      expect(workflow).to have_received(:run_activity)
        .with(Activities::CheckKnowledgeStalenessActivity, { project_id: 1 }, timeout: 30)
    end
  end

  describe "#maybe_evaluate_auto_release" do
    let(:workflow) { described_class.new }

    before do
      allow(workflow).to receive(:run_activity).and_return({})
    end

    it "runs EvaluateAutoReleaseActivity" do
      workflow.send(:maybe_evaluate_auto_release, 1)

      expect(workflow).to have_received(:run_activity)
        .with(Activities::EvaluateAutoReleaseActivity, { project_id: 1 }, timeout: 30)
    end
  end

  describe "#maybe_evaluate_dependabot_auto_merge" do
    let(:workflow) { described_class.new }

    before do
      allow(workflow).to receive(:run_activity).and_return({})
    end

    it "runs EvaluateDependabotAutoMergeActivity" do
      workflow.send(:maybe_evaluate_dependabot_auto_merge, 1)

      expect(workflow).to have_received(:run_activity)
        .with(Activities::EvaluateDependabotAutoMergeActivity, { project_id: 1 }, timeout: 30)
    end
  end

  describe "non-critical exhausted retry failures" do
    let(:workflow) { described_class.new }
    let(:logger) { instance_double(Logger, warn: nil) }

    before do
      allow(Temporalio::Workflow).to receive(:logger).and_return(logger)
    end

    it "records a metric when knowledge staleness checks fail after retries are exhausted" do
      error = exhausted_activity_error("CheckKnowledgeStalenessActivity")
      allow(workflow).to receive(:run_activity)
        .with(Activities::CheckKnowledgeStalenessActivity, { project_id: 7 }, timeout: 30)
        .and_raise(error)
      allow(workflow).to receive(:record_swallowed_non_critical_activity_failure)

      workflow.send(:maybe_check_knowledge_staleness, 7)

      expect(workflow).to have_received(:record_swallowed_non_critical_activity_failure).with(
        project_id: 7,
        helper: "maybe_check_knowledge_staleness",
        error: error
      )
      expect(logger).to have_received(:warn).with(hash_including(
        message: "knowledge.staleness_check_failed",
        project_id: 7
      ))
    end

    it "does not raise when request_review swallows an exhausted retry failure" do
      error = exhausted_activity_error("RequestReviewActivity")
      allow(workflow).to receive(:run_activity)
        .with(
          Activities::RequestReviewActivity,
          { project_id: 7, pr_number: 12, reviewers: [ "octocat" ] },
          timeout: 60
        )
        .and_raise(error)
      allow(workflow).to receive(:record_swallowed_non_critical_activity_failure)

      expect {
        workflow.send(:request_review, 7, 12, [ "octocat" ], log_key: "pr_review.request_review_failed")
      }.not_to raise_error

      expect(workflow).to have_received(:record_swallowed_non_critical_activity_failure).with(
        project_id: 7,
        helper: "request_review",
        error: error,
        pr_number: 12
      )
    end
  end

  describe "ScanSecurityAlertsActivity error handling" do
    let(:workflow) { described_class.new }

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

    it "swallows CodeScanningPermissionsError and continues the poll cycle" do
      config_error = Temporalio::Error::ApplicationError.new(
        "Token lacks security_events scope",
        type: "CodeScanningPermissionsError",
        non_retryable: true
      )
      activity_error = activity_error_with_cause(config_error)
      allow(workflow).to receive(:run_activity)
        .with(Activities::ScanSecurityAlertsActivity, anything, timeout: anything, heartbeat_timeout: anything)
        .and_raise(activity_error)

      logger = instance_double(Logger, warn: nil)
      allow(Temporalio::Workflow).to receive(:logger).and_return(logger)

      expect { workflow.send(:maybe_scan_code_scanning_alerts, 1) }.not_to raise_error

      expect(logger).to have_received(:warn).with(hash_including(
        message: "poll.code_scanning_configuration_error",
        project_id: 1
      ))
    end

    it "re-raises other ConfigurationErrors" do
      config_error = Temporalio::Error::ApplicationError.new(
        "No trusted GitHub usernames configured",
        type: "ConfigurationError",
        non_retryable: true
      )
      activity_error = activity_error_with_cause(config_error)
      allow(workflow).to receive(:run_activity)
        .with(Activities::ScanSecurityAlertsActivity, anything, timeout: anything, heartbeat_timeout: anything)
        .and_raise(activity_error)

      expect { workflow.send(:maybe_scan_code_scanning_alerts, 1) }
        .to raise_error(Temporalio::Error::ActivityError)
    end

    it "re-raises non-ConfigurationError ActivityErrors" do
      other_error = Temporalio::Error::ApplicationError.new(
        "Something else",
        type: "OtherError",
        non_retryable: true
      )
      activity_error = activity_error_with_cause(other_error)
      allow(workflow).to receive(:run_activity)
        .with(Activities::ScanSecurityAlertsActivity, anything, timeout: anything, heartbeat_timeout: anything)
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
          { project_id: project_id, issue_id: 10, source_pull_request_number: 42, goal: "create_pr", focus: "general" },
          timeout: 30)
    end

    # @spec PAGE-LOAD-FOLLOWUP-004
    it "forwards the focus evidence on a PR-scoped performance_regression decision" do
      evidence = { route_name: "dashboard", route_path: "/dashboard", comparison_metric: "lcp_ms" }
      evaluation = { decisions: [ { type: "queue_create_pr_run", issue_id: 10, source_pull_request_number: 42,
                                    focus: "performance_regression", focus_evidence: evidence } ] }

      workflow.send(:handle_automation_result, evaluation, project_id)

      expect(workflow).to have_received(:run_activity)
        .with(Activities::QueueAgentRunActivity,
          hash_including(project_id: project_id, issue_id: 10, source_pull_request_number: 42,
            goal: "create_pr", focus: "performance_regression", focus_evidence: evidence),
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

      stub_planning_workflow_start(workflow)
      allow(workflow).to receive(:run_activity)
        .with(Activities::FetchPlanReviewTimeoutActivity, anything, timeout: anything)
        .and_return({ plan_review_timeout_hours: 24 })

      workflow.send(:handle_automation_result, evaluation, project_id)

      expect(Temporalio::Workflow).to have_received(:start_child_workflow).with(
        Workflows::PlanningWorkflow,
        { project_id: project_id, issue_id: 20, plan_review_timeout_hours: 24 },
        hash_including(
          id: /\Aplan-#{project_id}-20-/,
          parent_close_policy: Temporalio::Workflow::ParentClosePolicy::ABANDON
        )
      )
    end

    it "starts FeatureOrchestrationWorkflow when feature_orchestration flag is enabled" do
      evaluation = { decisions: [ { type: "start_planning", issue_id: 20 } ] }

      allow(workflow).to receive(:run_activity)
        .with(Activities::LoadFeatureFlagsActivity, anything, timeout: anything)
        .and_return({ flags: { feature_orchestration: true } })
      allow(workflow).to receive(:run_activity)
        .with(Activities::CheckRunCapacityActivity, anything, timeout: anything)
        .and_return({ has_capacity: true })
      allow(Temporalio::Workflow).to receive(:now).and_return(Time.now)

      workflow.send(:handle_automation_result, evaluation, project_id)

      expect(Temporalio::Workflow).to have_received(:start_child_workflow).with(
        Workflows::FeatureOrchestrationWorkflow,
        { project_id: project_id, issue_id: 20 },
        hash_including(
          id: /\Aorchestrate-#{project_id}-20-/,
          parent_close_policy: Temporalio::Workflow::ParentClosePolicy::ABANDON
        )
      )
    end

    it "defers planning to future poll cycle when at capacity" do
      logger = instance_double(Logger, info: nil)
      allow(Temporalio::Workflow).to receive(:logger).and_return(logger)

      allow(workflow).to receive(:run_activity)
        .with(Activities::LoadFeatureFlagsActivity, anything, timeout: anything)
        .and_return({ flags: {} })
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

  describe "#quality_gate_allows_run?" do
    let(:project_id) { 1 }
    let(:pr_token_cap_block) do
      {
        allowed: false,
        reason: "pr_auto_continue_token_limit_exceeded",
        issue_id: 10,
        breaches: [ { metric: "pr_auto_continue_tokens", current: 50_000_000, threshold: 50_000_000 } ]
      }
    end

    before do
      allow(workflow).to receive(:quality_gate_allows_run?).and_call_original
      allow(Temporalio::Workflow).to receive_messages(logger: Rails.logger)
    end

    it "runs the quality gate activity and returns false when the gate blocks the run" do
      allow(workflow).to receive(:run_activity)
        .with(Activities::CheckQualityGateActivity, anything, timeout: anything)
        .and_return({ allowed: false, reason: "quality_gate_breached", breaches: [ { metric: "composite_score" } ] })

      result = workflow.send(:quality_gate_allows_run?, project_id, { issue_id: 10 }, goal: "create_pr")

      expect(result).to be(false)
      expect(workflow).to have_received(:run_activity)
        .with(Activities::CheckQualityGateActivity, hash_including(issue_id: 10, goal: "create_pr"), timeout: 30)
    end

    # @spec FOCUSED-RUN-007
    it "escalates the PR when the per-PR token cap blocks the run" do
      allow(workflow).to receive(:run_activity)
        .with(Activities::CheckQualityGateActivity, anything, timeout: anything)
        .and_return(pr_token_cap_block)
      allow(workflow).to receive(:run_activity)
        .with(Activities::MarkEscalatedActivity, anything, timeout: anything)
        .and_return({ updated: true })

      result = workflow.send(:quality_gate_allows_run?, project_id,
        { source_pull_request_number: 42 }, goal: "create_pr")

      expect(result).to be(false)
      expect(workflow).to have_received(:run_activity).with(
        Activities::MarkEscalatedActivity,
        hash_including(
          issue_id: 10,
          reason_key: "pr_auto_continue_token_limit",
          reason: "PR auto-continue token limit reached (50000000/50000000 recorded tokens)"
        ),
        timeout: 30
      )
    end
  end

  describe "#evaluate_issues_batch" do
    let(:workflow) { described_class.new }
    let(:project_id) { 1 }

    before do
      allow(workflow).to receive(:run_activity).and_return({})
    end

    it "calls EvaluateIssuesActivity with all issue IDs" do
      allow(workflow).to receive(:run_activity)
        .with(Activities::EvaluateIssuesActivity, anything, timeout: anything)
        .and_return({ results: [] })

      issues = [ { id: 10 }, { id: 20 }, { id: 30 } ]
      workflow.send(:evaluate_issues_batch, project_id, issues)

      expect(workflow).to have_received(:run_activity)
        .with(Activities::EvaluateIssuesActivity,
          { project_id: project_id, issue_ids: [ 10, 20, 30 ] }, timeout: 120, heartbeat_timeout: described_class::DEFAULT_HEARTBEAT_TIMEOUT)
    end

    it "dispatches each result through handle_automation_result" do
      allow(workflow).to receive(:run_activity)
        .with(Activities::EvaluateIssuesActivity, anything, timeout: anything, heartbeat_timeout: anything)
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
        .with(Activities::EvaluateIssuesActivity, anything, timeout: anything, heartbeat_timeout: anything)
        .and_return({ results: nil })

      expect { workflow.send(:evaluate_issues_batch, project_id, [ { id: 10 } ]) }
        .not_to raise_error
    end
  end

  describe "initial sync for existing PRs" do
    let(:workflow) { described_class.new }
    let(:project_id) { 1 }

    def stub_initial_sync(trigger_result:)
      allow(workflow).to receive(:run_activity).and_return({})
      allow(workflow).to receive(:run_activity)
        .with(Activities::CheckRateLimitActivity, { project_id: project_id }, timeout: 10)
        .and_return({ rate_limit_remaining: 500, rate_limit_low: false })
      allow(workflow).to receive(:run_activity)
        .with(Activities::FetchIssuesActivity, { project_id: project_id }, timeout: 60, heartbeat_timeout: described_class::DEFAULT_HEARTBEAT_TIMEOUT)
        .and_return(
          { issues: [ { id: 10 } ], project_id: project_id },
          { issues: [], project_id: project_id, project_missing: true }
        )
      allow(workflow).to receive(:run_activity)
        .with(Activities::ScanPaidPrsActivity, { project_id: project_id }, timeout: 300, heartbeat_timeout: described_class::DEFAULT_HEARTBEAT_TIMEOUT)
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
      allow(workflow).to receive(:interruptible_sleep)
      allow(workflow).to receive(:with_jitter) { |base| base }
      allow(workflow).to receive(:run_activity)
        .with(Activities::GetPollIntervalActivity, anything, timeout: anything)
        .and_return({ poll_interval_seconds: 60 })
      allow(workflow).to receive(:run_activity)
        .with(Activities::RecordPollHeartbeatActivity, anything, timeout: anything)
        .and_return({ recorded: true })
      allow(workflow).to receive(:run_activity)
        .with(Activities::ScanSecurityAlertsActivity, { project_id: project_id }, timeout: 120, heartbeat_timeout: described_class::DEFAULT_HEARTBEAT_TIMEOUT)
        .and_return({})
      allow(workflow).to receive(:run_activity)
        .with(Activities::CheckKnowledgeStalenessActivity, { project_id: project_id }, timeout: 30)
        .and_return({})
      allow(workflow).to receive(:run_activity)
        .with(Activities::EvaluateAutoReleaseActivity, { project_id: project_id }, timeout: 30)
        .and_return({})
      allow(workflow).to receive(:run_activity)
        .with(Activities::EvaluateDependabotAutoMergeActivity, { project_id: project_id }, timeout: 30)
        .and_return({})
      allow(workflow).to receive(:run_activity)
        .with(Activities::EvaluateNotificationRulesActivity, anything, timeout: anything)
        .and_return({})
      allow(workflow).to receive(:run_activity)
        .with(Activities::LoadFeatureFlagsActivity, { project_id: project_id }, timeout: 10)
        .and_return(flags: {}, project_missing: false)
      allow(workflow).to receive(:run_activity)
        .with(Activities::EvaluateIssuesActivity, anything, timeout: anything, heartbeat_timeout: anything)
        .and_return({ results: [ { decisions: [ { type: "noop" } ], action: "none", issue_id: 10, project_id: project_id } ] })
    end

    it "queues a review run when paid_agent_review_pending is the only initial-sync PR signal" do
      execute_initial_sync(trigger_result: {
        automation_results: [
          {
            decisions: [
              { type: "queue_review_run", issue_id: 10, source_pull_request_number: 42, focus: "general" }
            ]
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
      execute_initial_sync(trigger_result: { automation_results: [] })

      expect(workflow).not_to have_received(:run_activity)
        .with(Activities::QueueAgentRunActivity,
          hash_including(project_id: project_id, issue_id: 10,
            source_pull_request_number: 42, goal: "create_pr"),
          timeout: 30)
    end

    it "executes automation decisions from scan results" do
      allow(workflow).to receive(:run_activity)
        .with(Activities::QueueAgentRunActivity, anything, timeout: anything)
        .and_return({ queued: true })

      execute_initial_sync(trigger_result: {
        automation_results: [
          {
            decisions: [
              { type: "queue_review_run", issue_id: 10, source_pull_request_number: 42, focus: "general" }
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

    it "skips runs when automation results are all noop" do
      execute_initial_sync(trigger_result: {
        automation_results: [
          {
            decisions: [
              { type: "noop" }
            ]
          }
        ]
      })

      expect(workflow).not_to have_received(:run_activity)
        .with(Activities::QueueAgentRunActivity, anything, timeout: anything)
    end
  end

  describe "#handle_pr_scan_results" do
    let(:workflow) { described_class.new }
    let(:project_id) { 1 }

    before do
      allow(workflow).to receive(:run_activity).and_return({})
    end

    it "dispatches each automation result through handle_automation_result" do
      allow(workflow).to receive(:handle_automation_result)

      workflow.send(:handle_pr_scan_results, {
        automation_results: [
          { decisions: [ { type: "queue_create_pr_run", issue_id: 10 } ] },
          { decisions: [ { type: "noop" } ] }
        ]
      }, project_id)

      expect(workflow).to have_received(:handle_automation_result).twice
    end

    it "queues no runs when a PR scan returns no actionable triggers" do
      allow(workflow).to receive(:run_activity).and_call_original
      allow(workflow).to receive(:handle_automation_result)

      workflow.send(:handle_pr_scan_results, { automation_results: [] }, project_id)

      expect(workflow).not_to have_received(:handle_automation_result)
    end

    it "does not record a PR follow-up when a cross-goal duplicate blocked queueing" do
      allow(workflow).to receive(:run_activity)
        .with(Activities::QueueAgentRunActivity, anything, timeout: anything)
        .and_return({ queued: false, duplicate: true, cross_goal: true })

      workflow.send(:handle_pr_scan_results, {
        automation_results: [
          {
            decisions: [
              { type: "queue_create_pr_run", issue_id: 10, source_pull_request_number: 42, focus: "general" },
              { type: "record_pr_followup", issue_id: 10, labels_to_remove: [], expected_followup_count: 0 }
            ]
          }
        ]
      }, project_id)

      expect(workflow).not_to have_received(:run_activity)
        .with(Activities::RecordPrFollowupActivity, anything, timeout: anything)
    end

    it "records a PR follow-up when the create_pr run was queued" do
      allow(workflow).to receive(:run_activity)
        .with(Activities::QueueAgentRunActivity, anything, timeout: anything)
        .and_return({ queued: true })

      workflow.send(:handle_pr_scan_results, {
        automation_results: [
          {
            decisions: [
              { type: "queue_create_pr_run", issue_id: 10, source_pull_request_number: 42, focus: "general" },
              { type: "record_pr_followup", issue_id: 10, labels_to_remove: [], expected_followup_count: 0 }
            ]
          }
        ]
      }, project_id)

      expect(workflow).to have_received(:run_activity)
        .with(Activities::RecordPrFollowupActivity,
          { project_id: project_id, issue_id: 10, labels_to_remove: [], expected_followup_count: 0 },
          timeout: 30)
    end
  end
end
