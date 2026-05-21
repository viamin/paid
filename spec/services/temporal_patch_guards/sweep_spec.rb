# frozen_string_literal: true

require "rails_helper"

RSpec.describe TemporalPatchGuards::Sweep do
  let(:client_class) do
    Class.new do
      def list_workflows(_query); end
    end
  end
  let(:workflow_execution_class) do
    Struct.new(:start_time)
  end
  let(:client) { instance_double(client_class) }
  let(:entry_class) { TemporalPatchGuards::Registry.entries.first.class }

  describe "#call" do
    it "marks a guard eligible when no workflow of that type is still running" do
      entry = entry_class.new(
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
      entry = entry_class.new(
        name: "guard-a",
        workflow_type: "Workflows::GitHubPollWorkflow",
        introduced_on: Date.new(2026, 4, 7)
      )
      older_run = instance_double(workflow_execution_class, start_time: Time.utc(2026, 4, 7, 12))
      allow(client).to receive(:list_workflows)
        .with("WorkflowType = 'Workflows::GitHubPollWorkflow' AND ExecutionStatus = 'Running'")
        .and_return([ older_run ])

      report = described_class.new(client:, entries: [ entry ]).call

      expect(report.eligible_guards).to be_empty
    end

    it "keeps a guard in place when the oldest running workflow started at the sunset boundary" do
      entry = entry_class.new(
        name: "guard-a",
        workflow_type: "Workflows::GitHubPollWorkflow",
        introduced_on: Date.new(2026, 4, 7)
      )
      boundary_run = instance_double(workflow_execution_class, start_time: Time.utc(2026, 4, 8))
      allow(client).to receive(:list_workflows)
        .with("WorkflowType = 'Workflows::GitHubPollWorkflow' AND ExecutionStatus = 'Running'")
        .and_return([ boundary_run ])

      report = described_class.new(client:, entries: [ entry ]).call

      expect(report.eligible_guards).to be_empty
    end

    it "queries each workflow type once and uses the oldest running start time for all of its guards" do
      entries = [
        entry_class.new(
          name: "guard-a",
          workflow_type: "Workflows::GitHubPollWorkflow",
          introduced_on: Date.new(2026, 4, 7)
        ),
        entry_class.new(
          name: "guard-b",
          workflow_type: "Workflows::GitHubPollWorkflow",
          introduced_on: Date.new(2026, 4, 20)
        )
      ]
      older_run = instance_double(workflow_execution_class, start_time: Time.utc(2026, 4, 15))
      newer_run = instance_double(workflow_execution_class, start_time: Time.utc(2026, 4, 22))
      allow(client).to receive(:list_workflows)
        .with("WorkflowType = 'Workflows::GitHubPollWorkflow' AND ExecutionStatus = 'Running'")
        .once
        .and_return([ newer_run, older_run ])

      report = described_class.new(client:, entries:).call

      expect(report.eligible_guards.map(&:name)).to eq([ "guard-a" ])
    end
  end
end
