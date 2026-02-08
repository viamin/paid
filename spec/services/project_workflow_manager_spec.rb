# frozen_string_literal: true

require "rails_helper"

RSpec.describe ProjectWorkflowManager do
  let(:temporal_client) { instance_double(Temporalio::Client) }
  let(:project) { create(:project) }

  before do
    allow(Paid).to receive_messages(temporal_client: temporal_client, task_queue: "paid-tasks")
    allow(temporal_client).to receive(:start_workflow)
  end


  describe ".start_polling" do
    it "starts a GitHubPollWorkflow" do
      described_class.start_polling(project)

      expect(temporal_client).to have_received(:start_workflow).with(
        Workflows::GitHubPollWorkflow,
        { project_id: project.id },
        id: "github-poll-#{project.id}",
        task_queue: "paid-tasks"
      ).at_least(:once)
    end

    it "handles already-started workflow gracefully" do
      allow(temporal_client).to receive(:start_workflow).and_raise(
        Temporalio::Error::WorkflowAlreadyStartedError.new(
          workflow_id: "github-poll-#{project.id}",
          workflow_type: "GitHubPollWorkflow",
          run_id: "test-run-id"
        )
      )

      expect { described_class.start_polling(project) }.not_to raise_error
    end
  end

  describe ".stop_polling" do
    let(:workflow_handle) { double("workflow_handle") } # rubocop:disable RSpec/VerifiedDoubles

    it "cancels the polling workflow" do
      allow(temporal_client).to receive(:workflow_handle).and_return(workflow_handle)
      allow(workflow_handle).to receive(:cancel)

      described_class.stop_polling(project)

      expect(temporal_client).to have_received(:workflow_handle).with("github-poll-#{project.id}")
      expect(workflow_handle).to have_received(:cancel)
    end

    it "handles missing workflow gracefully" do
      allow(temporal_client).to receive(:workflow_handle).and_raise(
        Temporalio::Error::RPCError.new(
          "workflow not found",
          code: Temporalio::Error::RPCError::Code::NOT_FOUND,
          raw_grpc_status: nil
        )
      )

      expect { described_class.stop_polling(project) }.not_to raise_error
    end
  end
end
