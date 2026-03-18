# frozen_string_literal: true

require "rails_helper"

RSpec.describe AgentRuns::Cancel do
  let(:project) { create(:project) }
  let(:temporal_client) { instance_double(Temporalio::Client) }

  before do
    allow(Paid).to receive_messages(temporal_client: temporal_client, task_queue: "paid-tasks")
    allow(temporal_client).to receive(:start_workflow)
  end

  describe ".call" do
    context "when the run has no workflow or container" do
      let(:agent_run) { create(:agent_run, :running, project: project) }

      it "marks the run as cancelled" do
        described_class.call(agent_run: agent_run)

        agent_run.reload
        expect(agent_run.status).to eq("cancelled")
        expect(agent_run.completed_at).to be_present
      end
    end

    context "when the run has a temporal workflow" do
      let(:agent_run) do
        create(:agent_run, :running, project: project, temporal_workflow_id: "wf-123")
      end
      let(:workflow_handle) { instance_double(Temporalio::Client::WorkflowHandle) }

      before do
        allow(temporal_client).to receive(:workflow_handle).and_return(workflow_handle)
        allow(workflow_handle).to receive(:cancel)
      end

      it "cancels the temporal workflow" do
        described_class.call(agent_run: agent_run)

        expect(workflow_handle).to have_received(:cancel)
      end

      it "handles workflow not found gracefully" do
        allow(workflow_handle).to receive(:cancel).and_raise(
          Temporalio::Error::RPCError.new(
            "not found",
            code: Temporalio::Error::RPCError::Code::NOT_FOUND,
            raw_grpc_status: ""
          )
        )

        expect { described_class.call(agent_run: agent_run) }.not_to raise_error
        expect(agent_run.reload.status).to eq("cancelled")
      end
    end

    context "when the run has a container" do
      let(:agent_run) do
        create(:agent_run, :running, project: project, container_id: "abc123")
      end

      before do
        allow(agent_run).to receive(:cleanup_container)
      end

      it "cleans up the container" do
        described_class.call(agent_run: agent_run)

        expect(agent_run).to have_received(:cleanup_container).with(force: true)
      end
    end
  end
end
