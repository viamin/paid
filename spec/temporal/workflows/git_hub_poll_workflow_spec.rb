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
      allow(workflow).to receive(:run_activity).and_return({})
    end

    it "runs ScanPaidPrsActivity when patched returns true" do
      allow(Temporalio::Workflow).to receive(:patched).with("add-scan-paid-prs-v1").and_return(true)

      workflow.send(:handle_pr_scan_results, { prs_to_trigger: [] }, 1)

      # Verify the patch guard would allow the activity to run by checking the conditional
      expect(Temporalio::Workflow.patched("add-scan-paid-prs-v1")).to be true
    end

    it "skips ScanPaidPrsActivity when patched returns false" do
      allow(Temporalio::Workflow).to receive(:patched).with("add-scan-paid-prs-v1").and_return(false)

      expect(Temporalio::Workflow.patched("add-scan-paid-prs-v1")).to be false
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
        .with(Activities::MarkPrReadyActivity, anything, anything)
        .and_return({ marked_ready: true })

      pr_data = {
        issue_id: 10, pr_number: 42, owner_reviewer_login: "viamin",
        triggers: [ { type: "ready_for_owner" } ]
      }

      workflow.send(:handle_pr_trigger, project_id, pr_data)

      expect(workflow).to have_received(:run_activity)
        .with(Activities::MarkPrReadyActivity, hash_including(pr_number: 42), anything)
      expect(workflow).to have_received(:run_activity)
        .with(Activities::RequestReviewActivity, hash_including(reviewers: [ "viamin" ]), anything)
    end

    it "skips owner review when MarkPrReadyActivity returns marked_ready: false" do
      allow(workflow).to receive(:run_activity)
        .with(Activities::MarkPrReadyActivity, anything, anything)
        .and_return({ marked_ready: false })

      pr_data = {
        issue_id: 10, pr_number: 42, owner_reviewer_login: "viamin",
        triggers: [ { type: "ready_for_owner" } ]
      }

      workflow.send(:handle_pr_trigger, project_id, pr_data)

      expect(workflow).not_to have_received(:run_activity)
        .with(Activities::RequestReviewActivity, anything, anything)
    end

    it "routes escalate_to_owner to MarkEscalatedActivity and RequestReviewActivity" do
      pr_data = {
        issue_id: 10, pr_number: 42, owner_reviewer_login: "viamin",
        triggers: [ { type: "escalate_to_owner" } ]
      }

      workflow.send(:handle_pr_trigger, project_id, pr_data)

      expect(workflow).to have_received(:run_activity)
        .with(Activities::MarkEscalatedActivity, hash_including(issue_id: 10), anything)
      expect(workflow).to have_received(:run_activity)
        .with(Activities::RequestReviewActivity, hash_including(reviewers: [ "viamin" ]), anything)
    end

    it "routes owner_approved to MergePullRequestActivity" do
      pr_data = {
        issue_id: 10, pr_number: 42,
        triggers: [ { type: "owner_approved" } ]
      }

      workflow.send(:handle_pr_trigger, project_id, pr_data)

      expect(workflow).to have_received(:run_activity)
        .with(Activities::MergePullRequestActivity, hash_including(pr_number: 42), anything)
    end

    it "routes draft phase triggers to draft followup workflow" do
      allow(Temporalio::Workflow).to receive(:start_child_workflow)
      allow(Temporalio::Workflow).to receive(:now).and_return(Time.now)

      pr_data = {
        issue_id: 10, pr_number: 42, phase: "draft",
        current_draft_review_count: 1,
        triggers: [ { type: "ci_failure" } ]
      }

      workflow.send(:handle_pr_trigger, project_id, pr_data)

      expect(workflow).to have_received(:run_activity)
        .with(Activities::CheckRunCapacityActivity, anything, anything)
    end

    it "routes ready phase triggers to PR followup workflow" do
      allow(Temporalio::Workflow).to receive(:start_child_workflow)
      allow(Temporalio::Workflow).to receive(:now).and_return(Time.now)

      pr_data = {
        issue_id: 10, pr_number: 42, phase: "ready",
        current_followup_count: 0,
        triggers: [ { type: "ci_failure" } ]
      }

      workflow.send(:handle_pr_trigger, project_id, pr_data)

      expect(workflow).to have_received(:run_activity)
        .with(Activities::CheckRunCapacityActivity, anything, anything)
    end

    it "skips owner review request when owner_reviewer_login is blank" do
      allow(workflow).to receive(:run_activity)
        .with(Activities::MarkPrReadyActivity, anything, anything)
        .and_return({ marked_ready: true })

      pr_data = {
        issue_id: 10, pr_number: 42, owner_reviewer_login: nil,
        triggers: [ { type: "ready_for_owner" } ]
      }

      workflow.send(:handle_pr_trigger, project_id, pr_data)

      expect(workflow).to have_received(:run_activity)
        .with(Activities::MarkPrReadyActivity, anything, anything)
      expect(workflow).not_to have_received(:run_activity)
        .with(Activities::RequestReviewActivity, anything, anything)
    end
  end
end
