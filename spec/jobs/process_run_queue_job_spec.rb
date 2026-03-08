# frozen_string_literal: true

require "rails_helper"

RSpec.describe ProcessRunQueueJob do
  let(:temporal_client) { double("TemporalClient") } # rubocop:disable RSpec/VerifiedDoubles
  let(:workflow_handle) { double("WorkflowHandle", id: "queued-workflow-id") } # rubocop:disable RSpec/VerifiedDoubles

  before do
    allow(Paid).to receive_messages(temporal_client: temporal_client, task_queue: "paid-tasks")
    allow(temporal_client).to receive(:start_workflow).and_return(workflow_handle)
    allow(Rails.application.config.x).to receive(:max_concurrent_runs).and_return(2)
  end

  describe "#perform" do
    it "starts the oldest queued run when capacity is available" do
      queued_run = create(:agent_run, :queued, created_at: 2.minutes.ago)
      create(:agent_run, :queued, created_at: 1.minute.ago)

      expect(temporal_client).to receive(:start_workflow).with(
        Workflows::AgentExecutionWorkflow,
        hash_including(agent_run_id: queued_run.id),
        hash_including(task_queue: "paid-tasks")
      ).and_return(workflow_handle)

      described_class.new.perform

      expect(queued_run.reload.status).to eq("pending")
    end

    it "starts multiple queued runs up to capacity" do
      older = create(:agent_run, :queued, created_at: 2.minutes.ago)
      newer = create(:agent_run, :queued, created_at: 1.minute.ago)

      expect(temporal_client).to receive(:start_workflow).twice.and_return(workflow_handle)

      described_class.new.perform

      expect(older.reload.status).to eq("pending")
      expect(newer.reload.status).to eq("pending")
    end

    it "stops when capacity is exhausted" do
      create(:agent_run, :running)
      create(:agent_run, :running)
      queued_run = create(:agent_run, :queued)

      expect(temporal_client).not_to receive(:start_workflow)

      described_class.new.perform

      expect(queued_run.reload.status).to eq("queued")
    end

    it "does nothing when no queued runs exist" do
      create(:agent_run, :running)

      expect(temporal_client).not_to receive(:start_workflow)

      described_class.new.perform
    end

    it "processes runs in FIFO order" do
      older = create(:agent_run, :queued, created_at: 3.minutes.ago)
      newer = create(:agent_run, :queued, created_at: 1.minute.ago)
      allow(Rails.application.config.x).to receive(:max_concurrent_runs).and_return(1)

      started_ids = []
      allow(temporal_client).to receive(:start_workflow) do |_wf, input, **_opts|
        started_ids << input[:agent_run_id]
        workflow_handle
      end

      described_class.new.perform

      expect(started_ids).to eq([ older.id ])
      expect(older.reload.status).to eq("pending")
      expect(newer.reload.status).to eq("queued")
    end

    it "marks run as failed and continues when workflow start fails" do
      failing_run = create(:agent_run, :queued, created_at: 2.minutes.ago)
      good_run = create(:agent_run, :queued, created_at: 1.minute.ago)

      allow(temporal_client).to receive(:start_workflow) do |_wf, input, **_opts|
        raise StandardError, "Connection refused" if input[:agent_run_id] == failing_run.id
        workflow_handle
      end

      described_class.new.perform

      expect(failing_run.reload.status).to eq("failed")
      expect(failing_run.reload.error_message).to include("Connection refused")
      expect(good_run.reload.status).to eq("pending")
    end

    it "re-queues run when user concurrency limit is reached" do
      allow(Rails.application.config.x).to receive(:max_concurrent_runs).and_return(5)
      project = create(:project)
      user = project.created_by
      user.settings.update!(max_concurrent_runs: 1)
      create(:agent_run, :running, project: project)
      queued_run = create(:agent_run, :queued, project: project)

      expect(temporal_client).not_to receive(:start_workflow)

      described_class.new.perform

      expect(queued_run.reload.status).to eq("queued")
    end

    it "skips blocked user and starts runs for other users" do
      allow(Rails.application.config.x).to receive(:max_concurrent_runs).and_return(5)

      blocked_project = create(:project)
      blocked_user = blocked_project.created_by
      blocked_user.settings.update!(max_concurrent_runs: 1)
      create(:agent_run, :running, project: blocked_project)
      blocked_run = create(:agent_run, :queued, project: blocked_project, created_at: 2.minutes.ago)

      other_project = create(:project)
      eligible_run = create(:agent_run, :queued, project: other_project, created_at: 1.minute.ago)

      expect(temporal_client).to receive(:start_workflow).once.and_return(workflow_handle)

      described_class.new.perform

      expect(blocked_run.reload.status).to eq("queued")
      expect(eligible_run.reload.status).to eq("pending")
    end

    context "when queue is empty with capacity available" do
      it "calls auto-pick and starts newly queued runs" do
        project = create(:project, auto_pick_enabled: true)
        issue = create(:issue, project: project)

        auto_pick_service = instance_double(Issues::AutoPick)
        allow(Issues::AutoPick).to receive(:new).with(project).and_return(auto_pick_service)
        allow(auto_pick_service).to receive(:call) do
          create(:agent_run, :queued, project: project, issue: issue)
        end

        described_class.new.perform

        expect(Issues::AutoPick).to have_received(:new).with(project)
        expect(AgentRun.last.status).to eq("pending")
      end

      it "only runs auto-pick once per job invocation" do
        project = create(:project, auto_pick_enabled: true)

        auto_pick_service = instance_double(Issues::AutoPick)
        allow(Issues::AutoPick).to receive(:new).with(project).and_return(auto_pick_service)
        allow(auto_pick_service).to receive(:call).and_return(nil)

        described_class.new.perform

        expect(auto_pick_service).to have_received(:call).once
      end

      it "skips projects with auto_pick_enabled disabled" do
        create(:project, auto_pick_enabled: false)

        expect(Issues::AutoPick).not_to receive(:new)

        described_class.new.perform
      end
    end

    it "includes workflow input fields from the agent run" do
      issue = create(:issue)
      queued_run = create(:agent_run, :queued,
        project: issue.project,
        issue: issue,
        custom_prompt: "Fix the bug",
        source_pull_request_number: 42)

      expect(temporal_client).to receive(:start_workflow).with(
        Workflows::AgentExecutionWorkflow,
        hash_including(
          project_id: queued_run.project_id,
          agent_run_id: queued_run.id,
          issue_id: issue.id,
          custom_prompt: "Fix the bug",
          source_pull_request_number: 42
        ),
        anything
      ).and_return(workflow_handle)

      described_class.new.perform
    end
  end
end
