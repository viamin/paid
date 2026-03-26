# frozen_string_literal: true

require "rails_helper"

RSpec.describe ProcessRunQueueJob do
  let(:temporal_client) { double("TemporalClient") } # rubocop:disable RSpec/VerifiedDoubles
  let(:workflow_handle) { double("WorkflowHandle", id: "queued-workflow-id") } # rubocop:disable RSpec/VerifiedDoubles

  before do
    allow(Paid).to receive_messages(temporal_client: temporal_client, task_queue: "paid-tasks")
    allow(temporal_client).to receive(:start_workflow).and_return(workflow_handle)
  end

  def create_auto_pick_project(account:, user:)
    create(:project,
      account: account,
      created_by: user,
      github_token: create(:github_token, account: account, created_by: user),
      auto_pick_enabled: true)
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

    it "starts multiple queued runs up to user capacity" do
      project = create(:project)
      project.created_by.settings.update!(max_concurrent_runs: 2)
      older = create(:agent_run, :queued, project: project, trigger_type: "manual", created_at: 2.minutes.ago)
      newer = create(:agent_run, :queued, project: project, trigger_type: "manual", created_at: 1.minute.ago)

      expect(temporal_client).to receive(:start_workflow).twice.and_return(workflow_handle)

      described_class.new.perform

      expect(older.reload.status).to eq("pending")
      expect(newer.reload.status).to eq("pending")
    end

    it "stops when user capacity is exhausted" do
      project = create(:project)
      user = project.created_by
      user.settings.update!(max_concurrent_runs: 2)
      create(:agent_run, :running, project: project)
      create(:agent_run, :running, project: project)
      queued_run = create(:agent_run, :queued, project: project)

      expect(temporal_client).not_to receive(:start_workflow)

      described_class.new.perform

      expect(queued_run.reload.status).to eq("queued")
    end

    it "does nothing when no queued runs exist" do
      create(:agent_run, :running)

      expect(temporal_client).not_to receive(:start_workflow)

      described_class.new.perform
    end

    it "processes runs in FIFO order within the same priority" do
      project = create(:project)
      project.created_by.settings.update!(max_concurrent_runs: 1)
      older = create(:agent_run, :queued, project: project, created_at: 3.minutes.ago)
      newer = create(:agent_run, :queued, project: project, created_at: 1.minute.ago)

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

    it "starts manual runs before automatic runs regardless of creation time" do
      project = create(:project)
      project.created_by.settings.update!(max_concurrent_runs: 1)
      auto = create(:agent_run, :queued, project: project, trigger_type: "automatic", created_at: 3.minutes.ago)
      manual = create(:agent_run, :queued, project: project, trigger_type: "manual", created_at: 1.minute.ago)

      started_ids = []
      allow(temporal_client).to receive(:start_workflow) do |_wf, input, **_opts|
        started_ids << input[:agent_run_id]
        workflow_handle
      end

      described_class.new.perform

      expect(started_ids).to eq([ manual.id ])
      expect(manual.reload.status).to eq("pending")
      expect(auto.reload.status).to eq("queued")
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

    it "fails run when project owner cannot be resolved" do
      project = create(:project)
      queued_run = create(:agent_run, :queued, project: project)
      allow(project).to receive(:effective_owner).and_return(nil)
      allow(queued_run).to receive(:project).and_return(project)
      allow(AgentRun).to receive(:peek_next_queued_run).and_return(queued_run, nil)

      expect(temporal_client).not_to receive(:start_workflow)

      described_class.new.perform

      expect(queued_run.reload.status).to eq("failed")
      expect(queued_run.error_message).to include("Cannot resolve project owner")
    end

    it "re-queues run when user concurrency limit is reached" do
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

    it "skips auto-pick when all queued runs are at capacity" do
      project = create(:project, auto_pick_enabled: true)
      user = project.created_by
      user.settings.update!(max_concurrent_runs: 1)
      create(:agent_run, :running, project: project)
      queued_run = create(:agent_run, :queued, project: project)

      described_class.new.perform

      expect(queued_run.reload.status).to eq("queued")
    end

    context "when seeding auto-pick work" do
      it "queues eligible auto-pick runs and starts them" do
        project = create(:project, auto_pick_enabled: true)
        issue = create(:issue, project: project)

        auto_pick_service = instance_double(Issues::AutoPick)
        allow(Issues::AutoPick).to receive(:new)
          .with(having_attributes(id: project.id))
          .and_return(auto_pick_service)
        call_count = 0
        allow(auto_pick_service).to receive(:call) do
          call_count += 1
          call_count == 1 ? create(:agent_run, :queued, project: project, issue: issue) : nil
        end

        described_class.new.perform

        expect(Issues::AutoPick).to have_received(:new)
          .with(having_attributes(id: project.id)).at_least(:once)
        expect(AgentRun.last.status).to eq("pending")
      end

      it "stops seeding when no new runs are created" do
        project = create(:project, auto_pick_enabled: true)

        auto_pick_service = instance_double(Issues::AutoPick)
        allow(Issues::AutoPick).to receive(:new)
          .with(having_attributes(id: project.id))
          .and_return(auto_pick_service)
        allow(auto_pick_service).to receive(:call).and_return(nil)

        described_class.new.perform

        expect(auto_pick_service).to have_received(:call).once
      end

      it "skips projects with auto_pick_enabled disabled" do
        create(:project, auto_pick_enabled: false)

        expect(Issues::AutoPick).not_to receive(:new)

        described_class.new.perform
      end

      it "fills idle capacity from one project when no others have pickable work" do
        project = create(:project, auto_pick_enabled: true)
        user = project.created_by
        user.settings.update!(max_concurrent_runs: 4)

        4.times { create(:issue, project: project) }

        expect(temporal_client).to receive(:start_workflow).exactly(3).times.and_return(workflow_handle)

        described_class.new.perform

        expect(project.agent_runs.where(trigger_type: "automatic").count).to eq(4)
        expect(project.agent_runs.pending.count).to eq(3)
        expect(project.agent_runs.queued.count).to eq(1)
      end

      it "round robins auto-pick runs across projects before giving one project extra capacity" do
        account = create(:account)
        user = create(:user, account: account)
        user.settings.update!(max_concurrent_runs: 4)

        first_project = create_auto_pick_project(account: account, user: user)
        second_project = create_auto_pick_project(account: account, user: user)

        3.times { create(:issue, project: first_project) }
        3.times { create(:issue, project: second_project) }

        started_projects = []
        allow(temporal_client).to receive(:start_workflow) do |_wf, input, **_opts|
          started_projects << AgentRun.find(input[:agent_run_id]).project_id
          workflow_handle
        end

        described_class.new.perform

        expected_order = [ first_project, second_project, first_project ].map(&:id)
        expect(started_projects).to eq(expected_order)
        expect(first_project.agent_runs.pending.count).to eq(2)
        expect(second_project.agent_runs.pending.count).to eq(1)
      end

      it "reserves one active slot from being consumed by auto-pick runs" do
        project = create(:project, auto_pick_enabled: true)
        user = project.created_by
        user.settings.update!(max_concurrent_runs: 4)

        4.times { create(:issue, project: project) }

        described_class.new.perform

        expect(project.agent_runs.pending.count).to eq(3)
        expect(project.agent_runs.queued.count).to eq(1)
      end

      it "still starts a manual run with one slot reserved from auto-pick" do
        project = create(:project)
        user = project.created_by
        user.settings.update!(max_concurrent_runs: 4)

        3.times { create(:agent_run, :running, project: project, trigger_type: "automatic") }
        manual_run = create(:agent_run, :queued, project: project, trigger_type: "manual")

        expect(temporal_client).to receive(:start_workflow).with(
          Workflows::AgentExecutionWorkflow,
          hash_including(agent_run_id: manual_run.id),
          hash_including(task_queue: "paid-tasks")
        ).and_return(workflow_handle)

        described_class.new.perform

        expect(manual_run.reload.status).to eq("pending")
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
