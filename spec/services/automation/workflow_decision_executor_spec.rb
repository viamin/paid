# frozen_string_literal: true

require "rails_helper"

RSpec.describe Automation::WorkflowDecisionExecutor do
  describe ".call" do
    let(:workflow) { instance_double(Workflows::GitHubPollWorkflow) }

    before do
      allow(workflow).to receive(:execute_automation_decision)
    end

    it "delegates concrete decisions to the workflow decision entrypoint" do
      described_class.call(workflow:, project_id: 1, result: {
        decisions: [ { "type" => "dispatch_claude_review", "pr_number" => 42 } ]
      })

      expect(workflow).to have_received(:execute_automation_decision).with(
        project_id: 1,
        decision: { type: "dispatch_claude_review", pr_number: 42 }
      )
    end

    it "delegates unknown decisions to the workflow decision entrypoint" do
      described_class.call(workflow:, project_id: 1, result: {
        decisions: [ { type: "future_decision_type" } ]
      })

      expect(workflow).to have_received(:execute_automation_decision).with(
        project_id: 1,
        decision: { type: "future_decision_type" }
      )
    end

    it "does not record a PR follow-up when quality gates blocked create_pr queueing" do
      allow(workflow).to receive(:execute_automation_decision)
        .with(project_id: 1, decision: hash_including(type: "queue_create_pr_run"))
        .and_return(nil)

      described_class.call(workflow:, project_id: 1, result: {
        decisions: [
          { type: "queue_create_pr_run", issue_id: 10 },
          { type: "record_pr_followup", issue_id: 10, labels_to_remove: [], expected_followup_count: 0 }
        ]
      })

      expect(workflow).not_to have_received(:execute_automation_decision)
        .with(project_id: 1, decision: hash_including(type: "record_pr_followup"))
    end

    it "records a PR follow-up when create_pr queueing returns a queued result" do
      allow(workflow).to receive(:execute_automation_decision)
        .with(project_id: 1, decision: hash_including(type: "queue_create_pr_run"))
        .and_return({ queued: true })

      described_class.call(workflow:, project_id: 1, result: {
        decisions: [
          { type: "queue_create_pr_run", issue_id: 10 },
          { type: "record_pr_followup", issue_id: 10, labels_to_remove: [], expected_followup_count: 0 }
        ]
      })

      expect(workflow).to have_received(:execute_automation_decision)
        .with(project_id: 1, decision: hash_including(type: "record_pr_followup"))
    end
  end
end
