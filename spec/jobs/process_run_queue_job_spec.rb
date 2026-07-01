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

    it "does not start lower-priority work while higher-priority work from the same project is running" do
      project = create(:project)
      user = project.created_by
      user.settings.update!(max_concurrent_runs: 10)

      3.times do |i|
        p1_issue = create(:issue, project: project, github_number: 100 + i, labels: [ "P1" ])
        create(:agent_run, :running, project: project, trigger_type: "automatic", issue: p1_issue)
      end
      p2_issue = create(:issue, project: project, github_number: 200, labels: [ "P2" ])
      p2_run = create(:agent_run, :queued, project: project, trigger_type: "automatic", issue: p2_issue)

      expect(temporal_client).not_to receive(:start_workflow)

      described_class.new.perform

      expect(p2_run.reload.temporal_workflow_id).to be_nil
    end

    it "does not let paused or completed higher-priority work block lower-priority work" do
      project = create(:project)
      user = project.created_by
      user.settings.update!(max_concurrent_runs: 10)

      # A P1 blocked/paused (e.g. quality pause or awaiting input) and a P1
      # whose run already finished (PR now sitting in review) are not in
      # flight, so neither should preempt runnable lower-priority work.
      paused_p1 = create(:issue, project: project, github_number: 1, labels: [ "P1" ])
      create(:agent_run, :paused, project: project, trigger_type: "automatic", issue: paused_p1)
      done_p1 = create(:issue, project: project, github_number: 2, labels: [ "P1" ])
      create(:agent_run, :completed, project: project, trigger_type: "automatic", issue: done_p1)

      p2_issue = create(:issue, project: project, github_number: 3, labels: [ "P2" ])
      p2_run = create(:agent_run, :queued, project: project, trigger_type: "automatic", issue: p2_issue)

      expect(temporal_client).to receive(:start_workflow).with(
        Workflows::AgentExecutionWorkflow,
        hash_including(agent_run_id: p2_run.id),
        hash_including(task_queue: "paid-agent-tasks")
      ).and_return(workflow_handle)

      described_class.new.perform

      expect(p2_run.reload.temporal_workflow_id).to be_present
    end

    it "lets a queued run start when only lower-priority work is in flight" do
      project = create(:project)
      user = project.created_by
      user.settings.update!(max_concurrent_runs: 10)

      # A lower-priority auto-pick run is in flight; it must not block higher-priority queued work.
      create(:agent_run, :running, project: project, trigger_type: "automatic")
      p2_issue = create(:issue, project: project, github_number: 200, labels: [ "P2" ])
      p2_run = create(:agent_run, :queued, project: project, trigger_type: "automatic", issue: p2_issue)

      expect(temporal_client).to receive(:start_workflow).with(
        Workflows::AgentExecutionWorkflow,
        hash_including(agent_run_id: p2_run.id),
        hash_including(task_queue: "paid-agent-tasks")
      ).and_return(workflow_handle)

      described_class.new.perform

      expect(p2_run.reload.temporal_workflow_id).to be_present
    end

    it "does not block equal-priority queued work (a running P1 allows another queued P1 to start)" do
      project = create(:project)
      user = project.created_by
      user.settings.update!(max_concurrent_runs: 10)

      # The guard blocks only STRICTLY higher-priority in-flight work (`<`), so
      # a second P1 must still be allowed to start alongside a running P1 —
      # otherwise a project could never run two same-tier items concurrently.
      running_p1 = create(:issue, project: project, github_number: 10, labels: [ "P1" ])
      create(:agent_run, :running, project: project, trigger_type: "automatic", issue: running_p1)
      queued_p1 = create(:issue, project: project, github_number: 11, labels: [ "P1" ])
      p1_run = create(:agent_run, :queued, project: project, trigger_type: "automatic", issue: queued_p1)

      expect(temporal_client).to receive(:start_workflow).with(
        Workflows::AgentExecutionWorkflow,
        hash_including(agent_run_id: p1_run.id),
        hash_including(task_queue: "paid-agent-tasks")
      ).and_return(workflow_handle)

      described_class.new.perform

      expect(p1_run.reload.temporal_workflow_id).to be_present
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

    it "never exceeds per-user capacity even when starting multiple queued runs" do
      project = create(:project)
      user = project.created_by
      user.settings.update!(max_concurrent_runs: 4)

      runs = 6.times.map { |i| create(:agent_run, :queued, project: project, created_at: (6 - i).minutes.ago) }

      started_ids = []
      allow(temporal_client).to receive(:start_workflow) do |_wf, input, **_opts|
        started_ids << input[:agent_run_id]
        workflow_handle
      end

      described_class.new.perform

      expect(started_ids.length).to eq(4)
      runs.first(4).each { |r| expect(r.reload.temporal_workflow_id).to be_present }
      runs.last(2).each { |r| expect(r.reload.temporal_workflow_id).to be_nil }
    end

    it "rechecks capacity from DB after each start and respects concurrent external starts" do
      project = create(:project)
      user = project.created_by
      user.settings.update!(max_concurrent_runs: 2)

      run1 = create(:agent_run, :queued, project: project, created_at: 3.minutes.ago)
      _run2 = create(:agent_run, :queued, project: project, created_at: 2.minutes.ago)
      _run3 = create(:agent_run, :queued, project: project, created_at: 1.minute.ago)

      started_ids = []
      allow(temporal_client).to receive(:start_workflow) do |_wf, input, **_opts|
        started_ids << input[:agent_run_id]
        if input[:agent_run_id] == run1.id
          create(:agent_run, :running, project: project)
        end
        workflow_handle
      end

      described_class.new.perform

      expect(started_ids.length).to eq(1)
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

    context "when runner preflight fails" do
      it "skips the run when the runner circuit is open" do
        project = create(:project)
        user = project.created_by
        runner = user.runners.kept_only.find_by!(runner_key: "claude", auth_type: "subscription")
        create(:runner_state, :circuit_open, user: user, runner_name: runner.state_key)
        queued_run = create(:agent_run, :queued, project: project, runner: runner)
        allow(Rails.logger).to receive(:info)

        expect(temporal_client).not_to receive(:start_workflow)

        described_class.new.perform

        expect(queued_run.reload.status).to eq("queued")
        expect(Rails.logger).to have_received(:info).with(hash_including(
          message: "process_run_queue.preflight_skip",
          reason: "circuit_open"
        ))
      end

      it "skips the run when the runner is rate limited" do
        project = create(:project)
        user = project.created_by
        runner = user.runners.kept_only.find_by!(runner_key: "claude", auth_type: "subscription")
        create(:runner_state, :rate_limited, user: user, runner_name: runner.state_key)
        queued_run = create(:agent_run, :queued, project: project, runner: runner)
        allow(Rails.logger).to receive(:info)

        expect(temporal_client).not_to receive(:start_workflow)

        described_class.new.perform

        expect(queued_run.reload.status).to eq("queued")
        expect(Rails.logger).to have_received(:info).with(hash_including(
          message: "process_run_queue.preflight_skip",
          reason: "rate_limited"
        ))
      end

      it "skips the run when an API-key runner has no secret" do
        project = create(:project)
        user = project.created_by
        provider_api_key = create(:provider_api_key, user: user)
        runner = create(:runner, user: user, runner_key: "cursor", auth_type: "api_key", provider_api_key: provider_api_key)
        queued_run = create(:agent_run, :queued, project: project, runner: runner)
        allow(Rails.logger).to receive(:info)

        allow(Runners::PreflightCheck).to receive(:call)
          .with(runner: runner, user: user)
          .and_return(Runners::PreflightCheck::Result.new(pass?: false, reason: "missing_api_key", runner_id: runner.id))

        expect(temporal_client).not_to receive(:start_workflow)

        described_class.new.perform

        expect(queued_run.reload.status).to eq("queued")
        expect(Rails.logger).to have_received(:info).with(hash_including(
          message: "process_run_queue.preflight_skip",
          reason: "missing_api_key"
        ))
      end

      it "starts a run from another project when one runner fails preflight" do
        blocked_project = create(:project)
        blocked_user = blocked_project.created_by
        blocked_runner = blocked_user.runners.kept_only.find_by!(runner_key: "claude", auth_type: "subscription")
        create(:runner_state, :circuit_open, user: blocked_user, runner_name: blocked_runner.state_key)
        blocked_run = create(:agent_run, :queued, project: blocked_project, runner: blocked_runner, created_at: 2.minutes.ago)

        other_project = create(:project)
        other_run = create(:agent_run, :queued, project: other_project, created_at: 1.minute.ago)

        expect(temporal_client).to receive(:start_workflow).once.and_return(workflow_handle)

        described_class.new.perform

        expect(blocked_run.reload.status).to eq("queued")
        expect(other_run.reload.status).to eq("queued")
        expect(other_run.reload.temporal_workflow_id).to be_present
      end

      it "bulk-skips runs with the same failed runner without repeated preflight checks" do
        stub_const("#{described_class}::MAX_ITERATIONS_PER_PERFORM", 5)

        project = create(:project)
        user = project.created_by
        user.settings.update!(max_concurrent_runs: 10)
        runner = user.runners.kept_only.find_by!(runner_key: "claude", auth_type: "subscription")
        create(:runner_state, :circuit_open, user: user, runner_name: runner.state_key)

        10.times { |i| create(:agent_run, :queued, project: project, runner: runner, created_at: (20 - i).minutes.ago) }

        allow(Runners::PreflightCheck).to receive(:call).and_call_original

        described_class.new.perform

        expect(Runners::PreflightCheck).to have_received(:call).once
      end
    end

    context "when account create_pr concurrency cap is configured" do
      it "does not start create_pr runs when account is at the create_pr cap" do
        project = create(:project)
        create(:tenant_setting, account: project.account, max_concurrent_create_pr_runs: 2)

        create(:agent_run, :running, project: project, goal: "create_pr")
        create(:agent_run, :running, project: project, goal: "create_pr")
        queued_run = create(:agent_run, :queued, project: project, goal: "create_pr")

        expect(temporal_client).not_to receive(:start_workflow)

        described_class.new.perform

        expect(queued_run.reload.status).to eq("queued")
      end

      it "still starts non-create_pr runs when create_pr cap is reached" do
        project = create(:project)
        create(:tenant_setting, account: project.account, max_concurrent_create_pr_runs: 1)

        create(:agent_run, :running, project: project, goal: "create_pr")
        create_pr_run = create(:agent_run, :queued, project: project, goal: "create_pr", created_at: 2.minutes.ago)
        other_run = create(:agent_run, :queued, project: project, goal: "create_issue", created_at: 1.minute.ago)

        expect(temporal_client).to receive(:start_workflow).once.and_return(workflow_handle)

        described_class.new.perform

        expect(create_pr_run.reload.status).to eq("queued")
        expect(other_run.reload.temporal_workflow_id).to be_present
      end

      it "starts create_pr runs for accounts with available capacity" do
        capped_project = create(:project)
        create(:tenant_setting, account: capped_project.account, max_concurrent_create_pr_runs: 1)
        create(:agent_run, :running, project: capped_project, goal: "create_pr")
        capped_run = create(:agent_run, :queued, project: capped_project, goal: "create_pr", created_at: 2.minutes.ago)

        open_project = create(:project)
        open_run = create(:agent_run, :queued, project: open_project, goal: "create_pr", created_at: 1.minute.ago)

        expect(temporal_client).to receive(:start_workflow).once.and_return(workflow_handle)

        described_class.new.perform

        expect(capped_run.reload.status).to eq("queued")
        expect(open_run.reload.temporal_workflow_id).to be_present
      end
    end

    context "when the dispatch circuit breaker is open for an account" do
      it "blocks all queued runs for that account in a single pass" do
        account = create(:account)
        project = create(:project, account: account)
        create(:dispatch_circuit_breaker, :open, account: account)
        runs = Array.new(3) { create(:agent_run, :queued, project: project) }

        expect(temporal_client).not_to receive(:start_workflow)

        described_class.new.perform

        expect(runs.map { |run| run.reload.status }).to all(eq("queued"))
      end

      it "does not starve other accounts when a halted account has a deep backlog" do
        stub_const("#{described_class}::MAX_ITERATIONS_PER_PERFORM", 4)

        halted_account = create(:account)
        halted_project = create(:project, account: halted_account)
        create(:dispatch_circuit_breaker, :open, account: halted_account)
        # More halted-account runs than the iteration budget so only the peek
        # exclusion (not in-memory skipping) lets the other account through.
        Array.new(5) { |i| create(:agent_run, :queued, project: halted_project, created_at: (20 - i).minutes.ago) }

        open_account = create(:account)
        open_project = create(:project, account: open_account)
        open_run = create(:agent_run, :queued, project: open_project, created_at: 1.minute.ago)

        expect(temporal_client).to receive(:start_workflow).once.and_return(workflow_handle)

        described_class.new.perform

        expect(open_run.reload.temporal_workflow_id).to be_present
      end
    end

    context "when the dispatch circuit breaker is half_open for an account" do
      it "allows a single probe run and blocks the rest until the interval elapses" do
        account = create(:account)
        project = create(:project, account: account)
        create(:dispatch_circuit_breaker, :half_open, account: account, last_probe_at: nil)
        probe_run = create(:agent_run, :queued, project: project, created_at: 2.minutes.ago)
        blocked_run = create(:agent_run, :queued, project: project, created_at: 1.minute.ago)

        expect(temporal_client).to receive(:start_workflow).once.and_return(workflow_handle)

        described_class.new.perform

        expect(probe_run.reload.temporal_workflow_id).to be_present
        expect(blocked_run.reload.status).to eq("queued")
      end

      it "stamps the dispatched probe run id on the breaker so only its outcome counts" do
        account = create(:account)
        project = create(:project, account: account)
        breaker = create(:dispatch_circuit_breaker, :half_open, account: account, last_probe_at: nil)
        probe_run = create(:agent_run, :queued, project: project, created_at: 2.minutes.ago)

        allow(temporal_client).to receive(:start_workflow).and_return(workflow_handle)

        described_class.new.perform

        expect(breaker.reload.last_probe_run_id).to eq(probe_run.id)
      end

      it "does not stamp the probe when the workflow start fails" do
        account = create(:account)
        project = create(:project, account: account)
        breaker = create(:dispatch_circuit_breaker, :half_open, account: account, last_probe_at: nil)
        probe_run = create(:agent_run, :queued, project: project, created_at: 2.minutes.ago)

        allow(temporal_client).to receive(:start_workflow).and_raise(StandardError, "Connection refused")

        described_class.new.perform

        expect(probe_run.reload.status).to eq("failed")
        # The probe never actually dispatched, so the breaker must stay
        # probeable instead of blocking recovery for the probe interval.
        expect(breaker.reload.last_probe_run_id).to be_nil
        expect(breaker.reload.last_probe_at).to be_nil
      end

      it "does not stamp the probe when the claim is lost before dispatch" do
        account = create(:account)
        project = create(:project, account: account)
        breaker = create(:dispatch_circuit_breaker, :half_open, account: account, last_probe_at: nil)
        lost_run = create(:agent_run, :queued, project: project, created_at: 2.minutes.ago)

        # Another process wins the claim between peek and claim.
        allow(AgentRun).to receive(:claim_next_queued_run).and_return(nil)

        expect(temporal_client).not_to receive(:start_workflow)

        described_class.new.perform

        expect(lost_run.reload.status).to eq("queued")
        expect(breaker.reload.last_probe_run_id).to be_nil
        expect(breaker.reload.last_probe_at).to be_nil
      end

      it "keeps the breaker probeable so the next run retries when a probe start fails" do
        account = create(:account)
        project = create(:project, account: account)
        breaker = create(:dispatch_circuit_breaker, :half_open, account: account, last_probe_at: nil)
        failed_probe = create(:agent_run, :queued, project: project, created_at: 3.minutes.ago)
        retry_run = create(:agent_run, :queued, project: project, created_at: 2.minutes.ago)

        allow(temporal_client).to receive(:start_workflow) do |_wf, input, **_opts|
          raise StandardError, "Connection refused" if input[:agent_run_id] == failed_probe.id

          workflow_handle
        end

        described_class.new.perform

        expect(failed_probe.reload.status).to eq("failed")
        # The failed probe was not stamped, so the next run in the same pass
        # is treated as a fresh probe and the breaker records it on dispatch.
        expect(breaker.reload.last_probe_run_id).to eq(retry_run.id)
        expect(retry_run.reload.temporal_workflow_id).to be_present
      end
    end

    context "with Capacity::Policy gating" do
      it "dispatches under manual limits when auto mode is disabled by deployment policy" do
        # auto_allowed: false means "stay in manual mode", not "block all dispatch".
        # With headroom under the user's manual limit, the run should start.
        queued_run = create_queued_run_with_policy(max_concurrent_runs: 5)
        stub_policy_decision(remote_backend_decision)

        expect(temporal_client).to receive(:start_workflow)

        described_class.new.perform

        expect(queued_run.reload.temporal_workflow_id).to be_present
      end

      it "blocks dispatch when the user is at manual capacity even if auto ceiling is higher" do
        # remote_backend_decision has effective_max_concurrent: 10, but auto_allowed
        # is false so only the user's manual limit (2) governs concurrency.
        project = create(:project)
        project.created_by.settings.update!(max_concurrent_runs: 2)
        create(:agent_run, :running, project: project)
        create(:agent_run, :running, project: project)
        queued_run = create(:agent_run, :queued, project: project)
        stub_policy_decision(remote_backend_decision)

        expect(temporal_client).not_to receive(:start_workflow)

        described_class.new.perform

        expect(queued_run.reload.status).to eq("queued")
      end

      it "logs manual mode info when auto is disabled by deployment policy" do
        create_queued_run_with_policy(max_concurrent_runs: 5)
        stub_policy_decision(missing_snapshot_decision)
        allow(Rails.logger).to receive(:info)

        described_class.new.perform

        expect(Rails.logger).to have_received(:info).with(
          hash_including(
            message: "process_run_queue.capacity_policy_manual_mode",
            mode: "manual"
          )
        )
      end

      it "falls back to manual limits when the policy cannot be resolved" do
        project = create(:project)
        project.created_by.settings.update!(max_concurrent_runs: 1)
        queued_run = create(:agent_run, :queued, project: project)
        create(:agent_run, :running, project: project)

        # When DockerSnapshot.call raises, ProcessRunQueueJob should
        # log the error and fall back to the legacy tenant_max_concurrent_runs
        # limit (fail-safe, not fail-loud).
        allow(Capacity::DockerSnapshot).to receive(:call).and_raise(StandardError, "docker unavailable")

        expect(temporal_client).not_to receive(:start_workflow)

        described_class.new.perform

        expect(queued_run.reload.status).to eq("queued")
      end
    end
  end

  def create_queued_run_with_policy(max_concurrent_runs:)
    project = create(:project)
    project.created_by.settings.update!(max_concurrent_runs: max_concurrent_runs)
    create(:agent_run, :queued, project: project)
  end

  def stub_policy_decision(decision)
    allow(Capacity::Policy).to receive(:call).and_return(decision)
  end

  def remote_backend_decision
    remote_snapshot = Capacity::DockerSnapshot::Snapshot.new(
      backend_identifier: "remote",
      backend_kind: "remote",
      backend_shared: true,
      docker_cpu_count: 8,
      docker_memory_bytes: 16_000_000_000,
      usage_buckets: {},
      available_memory_bytes: 8_000_000_000,
      agent_container_count: 0,
      snapshot_at: Time.current,
      confidence: 1.0,
      degraded: false,
      degraded_reasons: []
    )

    allow(Capacity::DockerSnapshot).to receive(:call).and_return(remote_snapshot)

    Capacity::Policy::Decision.new(
      mode: Capacity::Policy::MANUAL,
      environment: Capacity::Policy::ENVIRONMENT_LINUX_DOCKER,
      auto_allowed: false,
      auto_allowed_reasons: [ "deployment_gate" ],
      blocked_reasons: [ Capacity::BlockedReason[:auto_mode_disabled_for_deployment] ],
      admission_uses_cpu: false,
      degraded: false,
      degraded_reasons: [],
      effective_min_concurrent: 1,
      effective_max_concurrent: 10,
      memory_safety_multiplier: 1.5,
      cooldown_seconds: 300,
      snapshot_present: true
    )
  end

  def missing_snapshot_decision
    allow(Capacity::DockerSnapshot).to receive(:call).and_return(nil)

    Capacity::Policy::Decision.new(
      mode: Capacity::Policy::MANUAL,
      environment: Capacity::Policy::ENVIRONMENT_UNKNOWN,
      auto_allowed: false,
      auto_allowed_reasons: [ "metrics_missing" ],
      blocked_reasons: [ Capacity::BlockedReason[:docker_unavailable] ],
      admission_uses_cpu: false,
      degraded: true,
      degraded_reasons: [ "no_snapshot" ],
      effective_min_concurrent: 1,
      effective_max_concurrent: 4,
      memory_safety_multiplier: 1.75,
      cooldown_seconds: 600,
      snapshot_present: false
    )
  end
end
