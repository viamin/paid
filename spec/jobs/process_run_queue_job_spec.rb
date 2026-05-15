# frozen_string_literal: true

require "rails_helper"

RSpec.describe ProcessRunQueueJob do
  let(:temporal_client) { double("TemporalClient") } # rubocop:disable RSpec/VerifiedDoubles
  let(:workflow_handle) { double("WorkflowHandle", id: "queued-workflow-id") } # rubocop:disable RSpec/VerifiedDoubles

  before do
    allow(Paid).to receive_messages(temporal_client: temporal_client, agent_task_queue: "paid-agent-tasks")
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

    context "when seeding auto-pick work" do
      it "queues eligible auto-pick runs and starts them" do
        project = create(:project, auto_pick_enabled: true)
        issue = create(:issue, project: project)

        created_run = nil
        call_count = 0
        allow(Issues::BulkEnqueueEligible).to receive(:call)
          .with(project: having_attributes(id: project.id), limit: 1) do
            call_count += 1
            if call_count == 1
              created_run = create(:agent_run, :queued, project: project, issue: issue)
              [ created_run ]
            else
              []
            end
          end

        described_class.new.perform

        expect(Issues::BulkEnqueueEligible).to have_received(:call)
          .with(project: having_attributes(id: project.id), limit: 1).at_least(:once)
        expect(created_run.reload.status).to eq("queued")
      end

      it "stops seeding when no new runs are created" do
        project = create(:project, auto_pick_enabled: true)

        allow(Issues::BulkEnqueueEligible).to receive(:call)
          .with(project: having_attributes(id: project.id), limit: 1)
          .and_return([])

        described_class.new.perform

        expect(Issues::BulkEnqueueEligible).to have_received(:call).once
      end

      it "skips projects with auto_pick_enabled disabled" do
        create(:project, auto_pick_enabled: false)

        expect(Issues::BulkEnqueueEligible).not_to receive(:call)

        described_class.new.perform
      end

      it "seeds at most one new auto-pick run per project in each pass" do
        stub_const("#{described_class}::MAX_SEEDS_PER_PERFORM", 2)
        account = create(:account)
        user = create(:user, account: account)
        user.settings.update!(max_concurrent_runs: 2)
        first_project = create_auto_pick_project(account: account, user: user)
        second_project = create_auto_pick_project(account: account, user: user)
        2.times { create(:issue, project: first_project) }
        2.times { create(:issue, project: second_project) }

        described_class.new.perform

        expect(first_project.agent_runs.where(auto_pick: true).count).to eq(1)
        expect(second_project.agent_runs.where(auto_pick: true).count).to eq(1)
      end

      it "skips auto-pick seeding for projects whose account is paused" do
        paused_account = create(:account, scheduler_paused_at: Time.current)
        paused_user = create(:user, account: paused_account)
        create_auto_pick_project(account: paused_account, user: paused_user)

        expect(Issues::BulkEnqueueEligible).not_to receive(:call)

        described_class.new.perform
      end

      it "skips auto-pick seeding when open PRs already need attention" do
        project = create(:project, auto_pick_enabled: true)
        project.created_by.settings.update!(max_auto_pick_open_prs: 1)
        create(:issue, :pull_request,
          project: project,
          github_state: "open",
          paid_state: "failed")
        create(:issue, project: project)

        expect(Issues::BulkEnqueueEligible).not_to receive(:call)

        described_class.new.perform
      end

      it "still seeds auto-pick work when paid-ready PRs no longer need attention" do
        project = create(:project, auto_pick_enabled: true)
        project.created_by.settings.update!(max_auto_pick_open_prs: 1)
        create(:issue, :pull_request,
          project: project,
          github_state: "open",
          paid_state: "in_progress",
          labels: [ project.automation_label_name, "paid-ready" ],
          pr_review_phase: "ready")
        issue = create(:issue, project: project)

        created_run = nil
        allow(Issues::BulkEnqueueEligible).to receive(:call)
          .with(project: having_attributes(id: project.id), limit: 1) do
            created_run = create(:agent_run, :queued, project: project, issue: issue)
            [ created_run ]
          end

        described_class.new.perform

        expect(Issues::BulkEnqueueEligible).to have_received(:call)
          .with(project: having_attributes(id: project.id), limit: 1).at_least(:once)
        expect(created_run.reload.status).to eq("queued")
      end

      it "fills idle capacity from one project when no others have pickable work" do
        project = create(:project, auto_pick_enabled: true)
        user = project.created_by
        user.settings.update!(max_concurrent_runs: 4)

        4.times { create(:issue, project: project) }

        expect(temporal_client).to receive(:start_workflow).exactly(4).times.and_return(workflow_handle)

        described_class.new.perform

        expect(project.agent_runs.where(trigger_type: "automatic").count).to eq(4)
        expect(project.agent_runs.claimed.count).to eq(4)
        expect(project.agent_runs.unclaimed.count).to eq(0)
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

        expected_order = [ first_project, second_project, first_project, second_project ].map(&:id)
        expect(started_projects).to eq(expected_order)
        expect(first_project.agent_runs.claimed.count).to eq(2)
        expect(second_project.agent_runs.claimed.count).to eq(2)
      end

      it "starts auto-pick runs up to the full user capacity" do
        project = create(:project, auto_pick_enabled: true)
        user = project.created_by
        user.settings.update!(max_concurrent_runs: 4)

        4.times { create(:issue, project: project) }

        described_class.new.perform

        expect(project.agent_runs.claimed.count).to eq(4)
        expect(project.agent_runs.unclaimed.count).to eq(0)
      end

      it "seeds every eligible auto-pick issue regardless of capacity" do
        project = create(:project, auto_pick_enabled: true)
        user = project.created_by
        user.settings.update!(max_concurrent_runs: 2)

        10.times { create(:issue, project: project) }

        described_class.new.perform

        expect(project.agent_runs.where(auto_pick: true).count).to eq(10)
        expect(project.agent_runs.where(auto_pick: true).claimed.count).to eq(2)
      end

      it "seeds new auto-pick runs even when in-flight auto-pick work already exists" do
        project = create(:project, auto_pick_enabled: true)
        user = project.created_by
        user.settings.update!(max_concurrent_runs: 2)

        create(:agent_run, :running, project: project, trigger_type: "automatic", auto_pick: true)
        5.times { create(:issue, project: project) }

        described_class.new.perform

        expect(project.agent_runs.where(auto_pick: true).count).to eq(6)
      end

      it "seeds all eligible issues across multiple projects owned by the same user" do
        account = create(:account)
        user = create(:user, account: account)
        user.settings.update!(max_concurrent_runs: 2)

        first_project = create_auto_pick_project(account: account, user: user)
        second_project = create_auto_pick_project(account: account, user: user)

        3.times { create(:issue, project: first_project) }
        3.times { create(:issue, project: second_project) }

        described_class.new.perform

        total_seeded = AgentRun.where(project: [ first_project, second_project ], auto_pick: true).count
        expect(total_seeded).to eq(6)
      end

      it "caps seeding at MAX_SEEDS_PER_PERFORM to bound DB load" do
        stub_const("#{described_class}::MAX_SEEDS_PER_PERFORM", 5)
        project = create(:project, auto_pick_enabled: true)
        user = project.created_by
        user.settings.update!(max_concurrent_runs: 1)

        (described_class::MAX_SEEDS_PER_PERFORM + 3).times { create(:issue, project: project) }

        described_class.new.perform

        expect(project.agent_runs.where(auto_pick: true).count).to eq(described_class::MAX_SEEDS_PER_PERFORM)
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

        expect(temporal_client).not_to receive(:start_workflow)

        described_class.new.perform
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
