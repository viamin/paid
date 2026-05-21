# frozen_string_literal: true

require "rails_helper"

RSpec.describe TemporalPatchGuards::Sweep do
  let(:client) { instance_double(Temporalio::Client) }

  describe "#call" do
    it "marks a guard eligible when no workflow of that type is still running" do
      entry = TemporalPatchGuards::Entry.new(
        name: "guard-a",
        workflow_type: "Workflows::GitHubPollWorkflow",
        introduced_on: Date.new(2026, 4, 7)
      )
      allow(client).to receive(:list_workflows)
        .with("WorkflowType = 'Workflows::GitHubPollWorkflow' AND ExecutionStatus = 'Running'")
        .and_return([])

      report = described_class.new(client:, entries: [ entry ]).call

      expect(report.eligible_guards.map(&:name)).to eq([ "guard-a" ])
    end

    it "keeps a guard in place when the oldest running workflow chain predates its sunset" do
      entry = TemporalPatchGuards::Entry.new(
        name: "guard-a",
        workflow_type: "Workflows::GitHubPollWorkflow",
        introduced_on: Date.new(2026, 4, 7)
      )
      older_run = instance_double(Temporalio::Client::WorkflowExecution, start_time: Time.utc(2026, 4, 7, 12))
      allow(client).to receive(:list_workflows)
        .with("WorkflowType = 'Workflows::GitHubPollWorkflow' AND ExecutionStatus = 'Running'")
        .and_return([ older_run ])

      report = described_class.new(client:, entries: [ entry ]).call

      expect(report.eligible_guards).to be_empty
    end

    it "queries each workflow type once and uses the oldest running start time for all of its guards" do
      entries = [
        TemporalPatchGuards::Entry.new(
          name: "guard-a",
          workflow_type: "Workflows::GitHubPollWorkflow",
          introduced_on: Date.new(2026, 4, 7)
        ),
        TemporalPatchGuards::Entry.new(
          name: "guard-b",
          workflow_type: "Workflows::GitHubPollWorkflow",
          introduced_on: Date.new(2026, 4, 20)
        )
      ]
      older_run = instance_double(Temporalio::Client::WorkflowExecution, start_time: Time.utc(2026, 4, 15))
      newer_run = instance_double(Temporalio::Client::WorkflowExecution, start_time: Time.utc(2026, 4, 22))
      allow(client).to receive(:list_workflows)
        .with("WorkflowType = 'Workflows::GitHubPollWorkflow' AND ExecutionStatus = 'Running'")
        .once
        .and_return([ newer_run, older_run ])

      report = described_class.new(client:, entries:).call

      expect(report.eligible_guards.map(&:name)).to eq([ "guard-a" ])
    end
  end
end
