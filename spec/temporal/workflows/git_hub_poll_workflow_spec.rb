# frozen_string_literal: true

require "rails_helper"

RSpec.describe Workflows::GitHubPollWorkflow do
  let(:workflow) { described_class.new }

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

  describe "#handle_detection" do
    let(:workflow) { described_class.new }
    let(:project_id) { 1 }

    before do
      allow(workflow).to receive(:run_activity)
        .with(Activities::CheckRunCapacityActivity, anything, timeout: anything)
        .and_return({ has_capacity: true })
      allow(Temporalio::Workflow).to receive(:start_child_workflow)
      allow(Temporalio::Workflow).to receive(:now).and_return(Time.now)
    end

    it "starts execute_agent child workflow with ABANDON parent close policy" do
      detection = { action: "execute_agent", issue_id: 10 }

      workflow.send(:handle_detection, detection, project_id)

      expect(Temporalio::Workflow).to have_received(:start_child_workflow).with(
        Workflows::AgentExecutionWorkflow,
        hash_including(project_id: project_id, issue_id: 10),
        hash_including(parent_close_policy: Temporalio::Workflow::ParentClosePolicy::ABANDON)
      )
    end

    it "starts PlanningWorkflow for start_planning action" do
      detection = { action: "start_planning", issue_id: 20 }

      workflow.send(:handle_detection, detection, project_id)

      expect(Temporalio::Workflow).to have_received(:start_child_workflow).with(
        Workflows::PlanningWorkflow,
        { project_id: project_id, issue_id: 20 },
        hash_including(
          id: /\Aplan-#{project_id}-20-/,
          parent_close_policy: Temporalio::Workflow::ParentClosePolicy::ABANDON
        )
      )
    end

    it "queues planning run when at capacity" do
      allow(workflow).to receive(:run_activity)
        .with(Activities::CheckRunCapacityActivity, anything, timeout: anything)
        .and_return({ has_capacity: false })
      allow(workflow).to receive(:run_activity)
        .with(Activities::QueueAgentRunActivity, anything, timeout: anything)
        .and_return({})

      detection = { action: "start_planning", issue_id: 20 }
      workflow.send(:handle_detection, detection, project_id)

      expect(Temporalio::Workflow).not_to have_received(:start_child_workflow)
        .with(Workflows::PlanningWorkflow, anything, anything)
      expect(workflow).to have_received(:run_activity)
        .with(Activities::QueueAgentRunActivity,
          { project_id: project_id, issue_id: 20 }, timeout: 30)
    end
  end

  describe "#handle_pr_trigger" do
    let(:workflow) { described_class.new }
    let(:project_id) { 1 }

    before do
      allow(workflow).to receive(:run_activity).and_return({})
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

    it "lets MarkEscalatedActivity compute the default reason" do
      pr_data = {
        issue_id: 10, pr_number: 42, owner_reviewer_login: "viamin",
        triggers: [ { type: "escalate_to_owner", details: "Draft review limit reached" } ]
      }

      workflow.send(:handle_pr_trigger, project_id, pr_data)

      expect(workflow).to have_received(:run_activity)
        .with(Activities::MarkEscalatedActivity,
          { issue_id: 10 }, timeout: anything)
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
      allow(Temporalio::Workflow).to receive(:start_child_workflow)
      allow(Temporalio::Workflow).to receive(:now).and_return(Time.now)
      allow(workflow).to receive(:run_activity)
        .with(Activities::CheckRunCapacityActivity, anything, timeout: anything)
        .and_return({ has_capacity: true })

      pr_data = {
        issue_id: 10, pr_number: 42, phase: "draft",
        current_draft_review_count: 1,
        triggers: [ { type: "ci_failure" } ]
      }

      workflow.send(:handle_pr_trigger, project_id, pr_data)

      expect(workflow).to have_received(:run_activity)
        .with(Activities::CheckRunCapacityActivity, anything, timeout: anything)
      expect(Temporalio::Workflow).to have_received(:start_child_workflow).with(
        Workflows::AgentExecutionWorkflow,
        hash_including(project_id: project_id, issue_id: 10, source_pull_request_number: 42),
        hash_including(parent_close_policy: Temporalio::Workflow::ParentClosePolicy::ABANDON)
      )
    end

    it "routes ready phase triggers to PR followup workflow" do
      allow(Temporalio::Workflow).to receive(:start_child_workflow)
      allow(Temporalio::Workflow).to receive(:now).and_return(Time.now)
      allow(workflow).to receive(:run_activity)
        .with(Activities::CheckRunCapacityActivity, anything, timeout: anything)
        .and_return({ has_capacity: true })

      pr_data = {
        issue_id: 10, pr_number: 42, phase: "ready",
        current_followup_count: 0,
        triggers: [ { type: "ci_failure" } ]
      }

      workflow.send(:handle_pr_trigger, project_id, pr_data)

      expect(workflow).to have_received(:run_activity)
        .with(Activities::CheckRunCapacityActivity, anything, timeout: anything)
      expect(Temporalio::Workflow).to have_received(:start_child_workflow).with(
        Workflows::AgentExecutionWorkflow,
        hash_including(project_id: project_id, issue_id: 10, source_pull_request_number: 42),
        hash_including(parent_close_policy: Temporalio::Workflow::ParentClosePolicy::ABANDON)
      )
    end

    it "routes review_bot_review_pending to RequestReviewActivity with copilot" do
      pr_data = {
        issue_id: 10, pr_number: 42, phase: "draft",
        current_draft_review_count: 0,
        triggers: [ { type: "review_bot_review_pending" } ]
      }

      workflow.send(:handle_pr_trigger, project_id, pr_data)

      expect(workflow).to have_received(:run_activity)
        .with(Activities::RequestReviewActivity,
          hash_including(reviewers: [ Activities::RequestReviewActivity::COPILOT_LOGIN ]), timeout: anything)
    end

    it "defers review request and dispatches followup when other triggers present" do
      allow(Temporalio::Workflow).to receive(:start_child_workflow)
      allow(Temporalio::Workflow).to receive(:now).and_return(Time.now)
      allow(workflow).to receive(:run_activity)
        .with(Activities::CheckRunCapacityActivity, anything, timeout: anything)
        .and_return({ has_capacity: true })

      pr_data = {
        issue_id: 10, pr_number: 42, phase: "draft",
        current_draft_review_count: 1,
        triggers: [
          { type: "review_bot_review_pending" },
          { type: "review_threads" }
        ]
      }

      workflow.send(:handle_pr_trigger, project_id, pr_data)

      # Review request is deferred to the AgentExecutionWorkflow (after push)
      expect(workflow).not_to have_received(:run_activity)
        .with(Activities::RequestReviewActivity,
          hash_including(reviewers: array_including(Activities::RequestReviewActivity::COPILOT_LOGIN)), timeout: anything)
      expect(Temporalio::Workflow).to have_received(:start_child_workflow)
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
  end
end
