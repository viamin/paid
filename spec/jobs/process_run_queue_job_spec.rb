# frozen_string_literal: true

require "rails_helper"

RSpec.describe ProcessRunQueueJob do
  let(:temporal_client) { double("TemporalClient") } # rubocop:disable RSpec/VerifiedDoubles
  let(:workflow_handle) { double("WorkflowHandle", id: "queued-workflow-id") } # rubocop:disable RSpec/VerifiedDoubles

  before do
    allow(Paid).to receive_messages(temporal_client: temporal_client, agent_task_queue: "paid-agent-tasks")
    allow(temporal_client).to receive(:start_workflow).and_return(workflow_handle)
  end

  describe "#perform" do
    it "starts the oldest queued run when capacity is available" do
      queued_run = create(:agent_run, :queued, created_at: 2.minutes.ago)
      create(:agent_run, :queued, created_at: 1.minute.ago)

      expect(temporal_client).to receive(:start_workflow).with(
        Workflows::AgentExecutionWorkflow,
        hash_including(agent_run_id: queued_run.id),
        hash_including(task_queue: "paid-agent-tasks")
      ).and_return(workflow_handle)

      described_class.new.perform

      queued_run.reload
      expect(queued_run.status).to eq("queued")
      expect(queued_run.temporal_workflow_id).to be_present
    end

    it "starts multiple queued runs up to user capacity" do
      project = create(:project)
      project.created_by.settings.update!(max_concurrent_runs: 2)
      older = create(:agent_run, :queued, project: project, trigger_type: "manual", created_at: 2.minutes.ago)
      newer = create(:agent_run, :queued, project: project, trigger_type: "manual", created_at: 1.minute.ago)

      expect(temporal_client).to receive(:start_workflow).twice.and_return(workflow_handle)

      described_class.new.perform

      expect(older.reload.status).to eq("queued")
      expect(newer.reload.status).to eq("queued")
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
      expect(older.reload.status).to eq("queued")
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
      expect(manual.reload.status).to eq("queued")
      expect(auto.reload.status).to eq("queued")
    end

    it "starts an older queued manual run before a later auto-continue followup" do
      project = create(:project)
      project.created_by.settings.update!(max_concurrent_runs: 1)
      manual = create(:agent_run, :queued, :manual, project: project, created_at: 2.minutes.ago)
      followup_issue = create(:issue, project: project)
      auto_continue = create(:agent_run, :queued, :automatic, :existing_pr,
        project: project, issue: followup_issue, created_at: 1.minute.ago)

      started_ids = []
      allow(temporal_client).to receive(:start_workflow) do |_wf, input, **_opts|
        started_ids << input[:agent_run_id]
        workflow_handle
      end

      described_class.new.perform

      expect(started_ids).to eq([ manual.id ])
      expect(manual.reload.status).to eq("queued")
      expect(auto_continue.reload.status).to eq("queued")
    end

    it "does not start lower-priority work from the same project after claiming a manual run" do
      project = create(:project)
      project.created_by.settings.update!(max_concurrent_runs: 2)
      manual = create(:agent_run, :queued, :manual, project: project, goal: "review", source_pull_request_number: 42,
        created_at: 2.minutes.ago)
      p1_issue = create(:issue, project: project, labels: [ "P1" ])
      p1_run = create(:agent_run, :queued, :automatic, project: project, issue: p1_issue, created_at: 1.minute.ago)

      started_ids = []
      allow(temporal_client).to receive(:start_workflow) do |_wf, input, **_opts|
        started_ids << input[:agent_run_id]
        workflow_handle
      end

      described_class.new.perform

      expect(started_ids).to eq([ manual.id ])
      expect(manual.reload.temporal_workflow_id).to be_present
      expect(p1_run.reload.temporal_workflow_id).to be_nil
    end

    it "does not start lower-priority work while a manual run from the same project is claimed" do
      project = create(:project)
      project.created_by.settings.update!(max_concurrent_runs: 2)
      create(:agent_run, :queued, :manual, project: project, goal: "review", source_pull_request_number: 42,
        temporal_workflow_id: AgentRun::CLAIMED_SENTINEL)
      p1_issue = create(:issue, project: project, labels: [ "P1" ])
      p1_run = create(:agent_run, :queued, :automatic, project: project, issue: p1_issue)

      expect(temporal_client).not_to receive(:start_workflow)

      described_class.new.perform

      expect(p1_run.reload.temporal_workflow_id).to be_nil
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
      expect(failing_run.configuration_bundle).to be_present
      expect(failing_run.reload.error_message).to include("Connection refused")
      # temporal_workflow_id is intentionally kept on failure so
      # StaleRunDetectorJob can cancel a potentially-orphaned workflow
      # (e.g. when start_workflow raises due to a network timeout but
      # the workflow actually started server-side).
      expect(failing_run.reload.temporal_workflow_id).to be_present
      expect(good_run.reload.status).to eq("queued")
    end

    it "enqueues finished-run followups when workflow start fails" do
      failing_run = create(:agent_run, :queued)

      allow(temporal_client).to receive(:start_workflow).and_raise(StandardError, "Connection refused")

      described_class.new.perform

      expect(QualityMetricsCollectionJob).to have_been_enqueued.with(failing_run.id)
      expect(AnomalyDetectionJob).to have_been_enqueued.with(failing_run.id)
      expect(DashboardBroadcastJob).to have_been_enqueued.with(failing_run.project.account_id)
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

    it "does not start queued runs when the account's scheduler is paused" do
      paused_account = create(:account, scheduler_paused_at: Time.current)
      paused_project = create(:project, account: paused_account, created_by: create(:user, account: paused_account))
      paused_run = create(:agent_run, :queued, project: paused_project)

      expect(temporal_client).not_to receive(:start_workflow)

      described_class.new.perform

      expect(paused_run.reload.status).to eq("queued")
    end

    it "still starts queued runs for accounts whose scheduler is not paused" do
      paused_account = create(:account, scheduler_paused_at: Time.current)
      paused_project = create(:project, account: paused_account, created_by: create(:user, account: paused_account))
      paused_run = create(:agent_run, :queued, project: paused_project, created_at: 2.minutes.ago)

      active_project = create(:project)
      active_run = create(:agent_run, :queued, project: active_project, created_at: 1.minute.ago)

      started_ids = []
      allow(temporal_client).to receive(:start_workflow) do |_wf, input, **_opts|
        started_ids << input[:agent_run_id]
        workflow_handle
      end

      described_class.new.perform

      expect(started_ids).to eq([ active_run.id ])
      expect(active_run.reload.status).to eq("queued")
      expect(paused_run.reload.status).to eq("queued")
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
      expect(eligible_run.reload.status).to eq("queued")
    end

    it "bulk-skips a blocked owner's backlog so later runnable owners are still reached" do
      stub_const("#{described_class}::MAX_ITERATIONS_PER_PERFORM", 5)

      blocked_project = create(:project)
      blocked_user = blocked_project.created_by
      blocked_user.settings.update!(max_concurrent_runs: 1)
      create(:agent_run, :running, project: blocked_project)
      10.times do |i|
        create(:agent_run, :queued, project: blocked_project, created_at: (20 - i).minutes.ago)
      end

      eligible_project = create(:project)
      eligible_run = create(:agent_run, :queued, project: eligible_project, created_at: 1.minute.ago)

      started_ids = []
      allow(temporal_client).to receive(:start_workflow) do |_wf, input, **_opts|
        started_ids << input[:agent_run_id]
        workflow_handle
      end

      described_class.new.perform

      expect(started_ids).to eq([ eligible_run.id ])
    end

    it "does not start queued runs when user is at capacity" do
      project = create(:project, auto_pick_enabled: true)
      user = project.created_by
      user.settings.update!(max_concurrent_runs: 1)
      create(:agent_run, :running, project: project)
      queued_run = create(:agent_run, :queued, project: project)

      described_class.new.perform

      expect(queued_run.reload.status).to eq("queued")
    end

    it "does not seed auto-pick work while dequeuing" do
      project = create(:project, auto_pick_enabled: true)
      create(:issue, project: project)

      allow(Issues::BulkEnqueueEligible).to receive(:call)

      described_class.new.perform

      expect(Issues::BulkEnqueueEligible).not_to have_received(:call)
    end

    it "starts a queued manual run alongside running auto-pick work" do
      project = create(:project)
      user = project.created_by
      user.settings.update!(max_concurrent_runs: 4)

      3.times { create(:agent_run, :running, project: project, trigger_type: "automatic") }
      manual_run = create(:agent_run, :queued, project: project, trigger_type: "manual")

      expect(temporal_client).to receive(:start_workflow).with(
        Workflows::AgentExecutionWorkflow,
        hash_including(agent_run_id: manual_run.id),
        hash_including(task_queue: "paid-agent-tasks")
      ).and_return(workflow_handle)

      described_class.new.perform

      expect(manual_run.reload.status).to eq("queued")
    end

    it "fails a budget-blocked run without consuming capacity or counting as a failure" do
      blocked_project = create(:project)
      user = blocked_project.created_by
      user.settings.update!(max_concurrent_runs: 2)
      create(:cost_budget, :hard_stop, :daily, project: blocked_project,
        limit_cents: 100, current_usage_cents: 200,
        period_started_at: Time.current.beginning_of_day)

      unblocked_project = create(:project, account: blocked_project.account, created_by: user)

      blocked_run = create(:agent_run, :queued, project: blocked_project, created_at: 2.minutes.ago)
      normal_run = create(:agent_run, :queued, project: unblocked_project, created_at: 1.minute.ago)

      expect(temporal_client).to receive(:start_workflow).once.and_return(workflow_handle)

      described_class.new.perform

      expect(blocked_run.reload.status).to eq("failed")
      expect(blocked_run.error_message).to include("Budget enforcement")
      expect(normal_run.reload.status).to eq("queued")
    end

    context "when GitHub circuit is open" do
      it "skips dispatching entirely" do
        create(:github_health_state, :circuit_open)
        create(:agent_run, :queued)
        allow(Rails.logger).to receive(:info)

        expect(temporal_client).not_to receive(:start_workflow)

        described_class.new.perform

        expect(Rails.logger).to have_received(:info).with(hash_including(
          message: "process_run_queue.skipped_github_unavailable",
          reason: "circuit_open"
        ))
      end

      it "attempts circuit recovery when timeout has elapsed" do
        state = create(:github_health_state, circuit_state: "open",
          circuit_opened_at: 10.minutes.ago, failure_count: 5)
        create(:agent_run, :queued)

        expect(temporal_client).to receive(:start_workflow).and_return(workflow_handle)

        described_class.new.perform

        expect(state.reload.circuit_state).to eq("half_open")
      end
    end

    context "when GitHub is rate limited" do
      let(:reset_at) { 30.minutes.from_now }
      let(:blocked_project) { create(:project) }
      let(:runnable_project) { create(:project) }
      let!(:blocked_run) { create(:agent_run, :queued, project: blocked_project, created_at: 2.minutes.ago) }
      let!(:runnable_run) { create(:agent_run, :queued, project: runnable_project, created_at: 1.minute.ago) }

      before do
        create(:github_health_state, endpoint: blocked_project.github_health_endpoint, rate_limited_until: reset_at)
        allow(Rails.logger).to receive(:info)
      end

      it "skips only runs for projects using the rate-limited credential" do
        expect(temporal_client).to receive(:start_workflow).with(
          Workflows::AgentExecutionWorkflow,
          hash_including(agent_run_id: runnable_run.id),
          hash_including(task_queue: "paid-agent-tasks")
        ).and_return(workflow_handle)

        described_class.new.perform

        expect(Rails.logger).to have_received(:info).with(hash_including(
          message: "process_run_queue.skipped_github_unavailable",
          project_id: blocked_project.id,
          reason: "rate_limited",
          available_at: reset_at.iso8601
        ))
        expect(blocked_run.reload.status).to eq("queued")
        expect(runnable_run.reload.temporal_workflow_id).to be_present
      end

      it "resumes dispatching once the rate-limit window has elapsed" do
        project = create(:project)
        create(:github_health_state, endpoint: project.github_health_endpoint, rate_limited_until: 1.minute.ago)
        create(:agent_run, :queued, project: project)

        expect(temporal_client).to receive(:start_workflow).and_return(workflow_handle)

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
