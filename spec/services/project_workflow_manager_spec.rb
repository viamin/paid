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

  describe ".workflow_status" do
    let(:workflow_handle) { double("workflow_handle") } # rubocop:disable RSpec/VerifiedDoubles

    before do
      allow(temporal_client).to receive(:workflow_handle).and_return(workflow_handle)
    end

    it "returns running status for a running workflow" do
      desc = double("description", status: Temporalio::Client::WorkflowExecutionStatus::RUNNING) # rubocop:disable RSpec/VerifiedDoubles
      allow(workflow_handle).to receive(:describe).and_return(desc)

      result = described_class.workflow_status(project)

      expect(result[:running]).to be true
      expect(result[:status]).to eq(Temporalio::Client::WorkflowExecutionStatus::RUNNING.to_s)
    end

    it "returns not running for a failed workflow" do
      desc = double("description", status: Temporalio::Client::WorkflowExecutionStatus::FAILED) # rubocop:disable RSpec/VerifiedDoubles
      allow(workflow_handle).to receive(:describe).and_return(desc)

      result = described_class.workflow_status(project)

      expect(result[:running]).to be false
      expect(result[:status]).to eq(Temporalio::Client::WorkflowExecutionStatus::FAILED.to_s)
    end

    it "returns not_found when workflow does not exist" do
      allow(temporal_client).to receive(:workflow_handle).and_raise(
        Temporalio::Error::RPCError.new(
          "workflow not found",
          code: Temporalio::Error::RPCError::Code::NOT_FOUND,
          raw_grpc_status: nil
        )
      )

      result = described_class.workflow_status(project)

      expect(result[:running]).to be false
      expect(result[:status]).to eq("not_found")
    end
  end

  describe ".restart_polling" do
    let(:workflow_handle) { double("workflow_handle") } # rubocop:disable RSpec/VerifiedDoubles

    it "terminates the workflow and starts a new one" do
      allow(temporal_client).to receive(:workflow_handle).and_return(workflow_handle)
      allow(workflow_handle).to receive(:terminate)

      described_class.restart_polling(project, reason: "test restart")

      expect(workflow_handle).to have_received(:terminate).with("test restart")
      expect(temporal_client).to have_received(:start_workflow).at_least(:once)
    end

    it "starts a new workflow even if terminate fails with not found" do
      allow(temporal_client).to receive(:workflow_handle).and_raise(
        Temporalio::Error::RPCError.new(
          "not found",
          code: Temporalio::Error::RPCError::Code::NOT_FOUND,
          raw_grpc_status: nil
        )
      )

      described_class.restart_polling(project)

      expect(temporal_client).to have_received(:start_workflow).at_least(:once)
    end
  end

  describe ".restart_all_polling" do
    it "restarts workflows for all polling-enabled projects" do
      polling_project = create(:project)

      workflow_handle = double("workflow_handle") # rubocop:disable RSpec/VerifiedDoubles
      allow(temporal_client).to receive(:workflow_handle).and_return(workflow_handle)
      allow(workflow_handle).to receive(:terminate)

      described_class.restart_all_polling(reason: "deploy")

      expect(temporal_client).to have_received(:workflow_handle)
        .with("github-poll-#{polling_project.id}").at_least(:once)
      expect(temporal_client).to have_received(:start_workflow).with(
        Workflows::GitHubPollWorkflow,
        { project_id: polling_project.id },
        id: "github-poll-#{polling_project.id}",
        task_queue: "paid-tasks"
      ).at_least(:once)
    end

    it "continues processing other projects when one fails" do
      create(:project)
      create(:project)

      call_count = 0
      allow(temporal_client).to receive(:workflow_handle) do
        call_count += 1
        if call_count == 1
          raise Temporalio::Error::RPCError.new(
            "connection error",
            code: Temporalio::Error::RPCError::Code::UNAVAILABLE,
            raw_grpc_status: nil
          )
        end
        wh = double("workflow_handle") # rubocop:disable RSpec/VerifiedDoubles
        allow(wh).to receive(:terminate)
        wh
      end

      expect { described_class.restart_all_polling }.not_to raise_error
    end
  end
end
