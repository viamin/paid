# frozen_string_literal: true

require "rails_helper"

RSpec.describe PollWorkflowHealthCheckJob do
  let(:temporal_client) { instance_double(Temporalio::Client) }

  before do
    allow(Paid).to receive_messages(temporal_client: temporal_client, task_queue: "paid-tasks")
    allow(temporal_client).to receive(:start_workflow)
  end

  describe "#perform" do
    it "restarts workflows that are not running" do
      project = create(:project)
      workflow_handle = double("workflow_handle") # rubocop:disable RSpec/VerifiedDoubles
      desc = double("description", status: Temporalio::Client::WorkflowExecutionStatus::FAILED) # rubocop:disable RSpec/VerifiedDoubles

      allow(temporal_client).to receive(:workflow_handle).and_return(workflow_handle)
      allow(workflow_handle).to receive(:describe).and_return(desc)
      allow(workflow_handle).to receive(:terminate)

      described_class.perform_now

      expect(workflow_handle).to have_received(:terminate)
      expect(temporal_client).to have_received(:start_workflow).with(
        Workflows::GitHubPollWorkflow,
        { project_id: project.id },
        id: "github-poll-#{project.id}",
        task_queue: "paid-tasks"
      ).at_least(:once)
    end

    it "skips workflows that are running" do
      create(:project)
      workflow_handle = double("workflow_handle") # rubocop:disable RSpec/VerifiedDoubles
      desc = double("description", status: Temporalio::Client::WorkflowExecutionStatus::RUNNING) # rubocop:disable RSpec/VerifiedDoubles

      allow(temporal_client).to receive(:workflow_handle).and_return(workflow_handle)
      allow(workflow_handle).to receive(:describe).and_return(desc)
      allow(workflow_handle).to receive(:terminate)

      described_class.perform_now

      expect(workflow_handle).not_to have_received(:terminate)
    end

    it "does nothing when no projects have polling enabled" do
      described_class.perform_now

      expect(temporal_client).not_to have_received(:start_workflow)
    end

    it "handles errors per-project without stopping the whole run" do
      create(:project)
      project2 = create(:project)
      stub_workflow_handle_with_first_call_error

      expect { described_class.perform_now }.not_to raise_error

      expect(temporal_client).to have_received(:start_workflow).with(
        Workflows::GitHubPollWorkflow,
        { project_id: project2.id },
        id: "github-poll-#{project2.id}",
        task_queue: "paid-tasks"
      ).at_least(:once)
    end
  end

  private

  def stub_workflow_handle_with_first_call_error
    call_count = 0
    allow(temporal_client).to receive(:workflow_handle) do
      call_count += 1
      raise StandardError, "connection error" if call_count == 1
      wh = double("workflow_handle") # rubocop:disable RSpec/VerifiedDoubles
      desc = double("description", status: Temporalio::Client::WorkflowExecutionStatus::FAILED) # rubocop:disable RSpec/VerifiedDoubles
      allow(wh).to receive(:describe).and_return(desc)
      allow(wh).to receive(:terminate)
      wh
    end
  end
end
