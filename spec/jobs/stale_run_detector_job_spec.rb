# frozen_string_literal: true

require "rails_helper"

RSpec.describe StaleRunDetectorJob do
  around do |example|
    Rails.cache.clear
    example.run
    Rails.cache.clear
  end

  # Running runs: legacy fallback used by the generic timeout examples
  let(:running_threshold) { AgentRun.default_stale_running_timeout.to_i }
  # Claimed queued runs: shorter dedicated threshold
  let(:claimed_threshold) { described_class::CLAIMED_TIMEOUT.to_i }
  # Paused runs: guardrail pauses should not block auto-pick indefinitely
  let(:paused_threshold) { described_class::PAUSED_TIMEOUT.to_i }

  describe "#perform" do
    it "times out runs stuck in running beyond the threshold" do
      stale_run = create(:agent_run, :running, started_at: (running_threshold + 60).seconds.ago)

      described_class.perform_now

      stale_run.reload
      expect(stale_run.status).to eq("timeout")
      expect(stale_run.error_message).to start_with(AgentRun::STALE_DETECTOR_ERROR_PREFIX)
      expect(stale_run.completed_at).to be_present
    end

    it "does not touch running runs within the threshold" do
      recent_run = create(:agent_run, :running, started_at: (running_threshold - 60).seconds.ago)

      described_class.perform_now

      expect(recent_run.reload.status).to eq("running")
    end

    it "does not touch completed or failed runs" do
      create(:agent_run, :completed, started_at: 2.days.ago)
      create(:agent_run, :failed, started_at: 2.days.ago)

      expect { described_class.perform_now }.not_to change { AgentRun.where(status: "timeout").count }
    end

    it "updates the issue paid_state to failed" do
      stale_run = create(:agent_run, :running, started_at: (running_threshold + 60).seconds.ago)
      stale_run.issue.update!(paid_state: "in_progress")

      described_class.perform_now

      expect(stale_run.issue.reload.paid_state).to eq("failed")
    end

    it "sets issue paid_state to completed for stale review-goal runs" do
      issue = create(:issue, :in_progress, :pull_request, project: create(:project))
      stale_run = create(:agent_run, :running, :review_goal, project: issue.project, issue: issue, started_at: (running_threshold + 60).seconds.ago)

      described_class.perform_now

      expect(stale_run.issue.reload.paid_state).to eq("completed")
    end

    it "creates a log entry on the resolved run" do
      stale_run = create(:agent_run, :running, started_at: (running_threshold + 60).seconds.ago)

      described_class.perform_now

      log = stale_run.agent_run_logs.last
      expect(log.content).to include("stale run detector")
    end

    it "triggers ProcessRunQueueJob when runs are resolved" do
      create(:agent_run, :running, started_at: (running_threshold + 60).seconds.ago)

      expect { described_class.perform_now }.to have_enqueued_job(ProcessRunQueueJob)
    end

    it "does not trigger ProcessRunQueueJob when no runs are resolved" do
      expect { described_class.perform_now }.not_to have_enqueued_job(ProcessRunQueueJob)
    end

    it "resolves multiple stale runs in a single pass" do
      stale_run1 = create(:agent_run, :running, started_at: (running_threshold + 120).seconds.ago)
      stale_run2 = create(:agent_run, :running, started_at: (running_threshold + 60).seconds.ago)

      described_class.perform_now

      expect(stale_run1.reload.status).to eq("timeout")
      expect(stale_run2.reload.status).to eq("timeout")
    end

    it "uses shorter adaptive thresholds for fast healthy goals" do
      allow(AgentRun).to receive(:healthy_successful_runtime_stats_by_goal).and_return(
        "review" => {
          count: AgentRun::STALE_RUNNING_HEALTHY_MIN_SAMPLE_SIZE,
          p95: 120.0
        }
      )

      stale_review = create(:agent_run, :running, :review_goal,
        started_at: (AgentRun.stale_running_timeout(goal: "review") + 60).seconds.ago)
      fresh_create_pr = create(:agent_run, :running,
        started_at: (AgentRun.stale_running_timeout(goal: "create_pr") - 60).seconds.ago)

      described_class.perform_now

      expect(stale_review.reload.status).to eq("timeout")
      expect(fresh_create_pr.reload.status).to eq("running")
    end

    it "calls cleanup_container when a run is timed out" do
      stale_run = create(:agent_run, :running, started_at: (running_threshold + 60).seconds.ago,
        container_id: "dead-container-123")
      container_service = instance_double(Containers::Provision, cleanup: true)
      allow(Containers::Provision).to receive(:reconnect).and_return(container_service)
      allow(Containers::ServiceProvisioner).to receive(:new)
        .and_return(instance_double(Containers::ServiceProvisioner, cleanup: nil))

      described_class.perform_now

      expect(container_service).to have_received(:cleanup).with(force: true)
      expect(stale_run.reload.container_id).to be_nil
    end

    it "calls ServiceProvisioner#cleanup when a run is timed out" do
      create(:agent_run, :running, started_at: (running_threshold + 60).seconds.ago)
      provisioner = instance_double(Containers::ServiceProvisioner, cleanup: nil)
      allow(Containers::ServiceProvisioner).to receive(:new).and_return(provisioner)

      described_class.perform_now

      expect(provisioner).to have_received(:cleanup)
    end

    it "still resolves the run when container cleanup fails" do
      stale_run = create(:agent_run, :running, started_at: (running_threshold + 60).seconds.ago,
        container_id: "dead-container-456")
      allow(Containers::Provision).to receive(:reconnect)
        .and_raise(Containers::Provision::ProvisionError, "gone")
      allow(Docker::Volume).to receive(:get)
        .and_raise(Docker::Error::NotFoundError, "no such volume")
      provisioner = instance_double(Containers::ServiceProvisioner, cleanup: nil)
      allow(Containers::ServiceProvisioner).to receive(:new).and_return(provisioner)

      described_class.perform_now

      expect(stale_run.reload.status).to eq("timeout")
      expect(provisioner).to have_received(:cleanup)
    end

    it "still resolves the run when service cleanup fails" do
      stale_run = create(:agent_run, :running, started_at: (running_threshold + 60).seconds.ago)
      allow(Containers::ServiceProvisioner).to receive(:new).and_raise(RuntimeError, "gone")

      described_class.perform_now

      expect(stale_run.reload.status).to eq("timeout")
    end

    context "with stale claimed runs" do
      before do
        handle = double(cancel: true) # rubocop:disable RSpec/VerifiedDoubles
        temporal_client = double(workflow_handle: handle, start_workflow: nil) # rubocop:disable RSpec/VerifiedDoubles
        allow(Paid).to receive(:temporal_client).and_return(temporal_client)
      end

      it "requeues a stale claimed run that has not exhausted requeue budget" do
        stale_run = create(:agent_run, status: "queued", temporal_workflow_id: "test-workflow-id")
        stale_run.update_columns(updated_at: (claimed_threshold + 60).seconds.ago)

        described_class.perform_now

        stale_run.reload
        expect(stale_run.status).to eq("queued")
        expect(stale_run.temporal_workflow_id).to be_nil
        expect(stale_run.stale_requeue_count).to eq(1)
      end

      it "creates a log entry when requeuing" do
        stale_run = create(:agent_run, status: "queued", temporal_workflow_id: "test-workflow-id")
        stale_run.update_columns(updated_at: (claimed_threshold + 60).seconds.ago)

        described_class.perform_now

        log = stale_run.agent_run_logs.last
        expect(log.content).to include("unclaimed")
        expect(log.content).to include("attempt 1/#{described_class::MAX_STALE_REQUEUES}")
      end

      it "triggers ProcessRunQueueJob when runs are requeued" do
        stale_run = create(:agent_run, status: "queued", temporal_workflow_id: "test-workflow-id")
        stale_run.update_columns(updated_at: (claimed_threshold + 60).seconds.ago)

        expect { described_class.perform_now }.to have_enqueued_job(ProcessRunQueueJob)
      end

      it "times out a stale claimed run that has exhausted requeue budget" do
        stale_run = create(:agent_run, status: "queued", temporal_workflow_id: "test-workflow-id", stale_requeue_count: described_class::MAX_STALE_REQUEUES)
        stale_run.update_columns(updated_at: (claimed_threshold + 60).seconds.ago)

        described_class.perform_now

        stale_run.reload
        expect(stale_run.status).to eq("timeout")
        expect(stale_run.error_message).to start_with(AgentRun::STALE_DETECTOR_ERROR_PREFIX)
      end

      it "does not touch claimed runs within the threshold" do
        recent_run = create(:agent_run, status: "queued", temporal_workflow_id: "test-workflow-id")
        recent_run.update_columns(updated_at: (claimed_threshold - 60).seconds.ago)

        described_class.perform_now

        expect(recent_run.reload.status).to eq("queued")
      end

      it "cleans up docker resources when requeuing" do
        stale_run = create(:agent_run, status: "queued", temporal_workflow_id: "test-workflow-id", container_id: "orphaned-container")
        stale_run.update_columns(updated_at: (claimed_threshold + 60).seconds.ago)
        container_service = instance_double(Containers::Provision, cleanup: true)
        allow(Containers::Provision).to receive(:reconnect).and_return(container_service)
        allow(Containers::ServiceProvisioner).to receive(:new)
          .and_return(instance_double(Containers::ServiceProvisioner, cleanup: nil))

        described_class.perform_now

        expect(container_service).to have_received(:cleanup).with(force: true)
      end

      it "destroys a claimed pool entry when requeue cleanup reconnects directly" do
        stale_run = create(:agent_run, status: "queued", temporal_workflow_id: "test-workflow-id", container_id: "pooled-container")
        stale_run.update_columns(updated_at: (claimed_threshold + 60).seconds.ago)
        entry = create(:container_pool_entry, :claimed,
          project: stale_run.project,
          agent_run: stale_run,
          container_id: stale_run.container_id)
        container = instance_double(Docker::Container,
          id: entry.container_id,
          refresh!: true,
          info: { "State" => { "Running" => true } },
          stop: true,
          delete: true)
        volume = instance_double(Docker::Volume, remove: true)

        allow(Docker::Container).to receive(:get).with(entry.container_id).and_return(container)
        allow(Docker::Volume).to receive(:get).with(entry.workspace_volume).and_return(volume)
        allow(Containers::ServiceProvisioner).to receive(:new)
          .and_return(instance_double(Containers::ServiceProvisioner, cleanup: nil))

        described_class.perform_now

        expect(ContainerPoolEntry.exists?(entry.id)).to be(false)
      end

      it "clears container_id and service_container_ids inside the lock on requeue" do
        stale_run = create(:agent_run, status: "queued", temporal_workflow_id: "test-workflow-id",
          container_id: "orphaned-container",
          service_container_ids: [ 1, 2, 3 ])
        stale_run.update_columns(updated_at: (claimed_threshold + 60).seconds.ago)
        container_service = instance_double(Containers::Provision, cleanup: true)
        allow(Containers::Provision).to receive(:reconnect).and_return(container_service)
        allow(Containers::ServiceProvisioner).to receive(:new)
          .and_return(instance_double(Containers::ServiceProvisioner, cleanup: nil))

        described_class.perform_now

        stale_run.reload
        expect(stale_run.status).to eq("queued")
        expect(stale_run.container_id).to be_nil
        expect(stale_run.service_container_ids).to eq([])
      end

      it "skips a run that transitioned out of claimed before unclaim" do
        run = create(:agent_run, status: "queued", temporal_workflow_id: "test-workflow-id")
        run.update_columns(updated_at: (claimed_threshold + 60).seconds.ago)
        run.update_columns(status: "running", started_at: Time.current, updated_at: Time.current)

        job = described_class.new
        result = job.send(:unclaim_stale_claimed_run, run)

        expect(result).to eq(:skip)
        expect(run.reload.status).to eq("running")
      end

      it "skips a claimed run that was recently updated (no longer stale)" do
        run = create(:agent_run, status: "queued", temporal_workflow_id: "test-workflow-id")
        run.update_columns(updated_at: 1.minute.ago)

        job = described_class.new
        result = job.send(:unclaim_stale_claimed_run, run)

        expect(result).to eq(:skip)
        expect(run.reload.status).to eq("queued")
      end

      it "does not requeue a claimed run just inside the threshold boundary" do
        # A run updated slightly less than CLAIMED_TIMEOUT ago is not stale
        boundary_run = create(:agent_run, status: "queued", temporal_workflow_id: "test-workflow-id")
        boundary_run.update_columns(updated_at: (claimed_threshold - 5).seconds.ago)

        described_class.perform_now

        expect(boundary_run.reload.status).to eq("queued")
      end

      it "increments requeue count on successive requeues" do
        stale_run = create(:agent_run, status: "queued", temporal_workflow_id: "test-workflow-id", stale_requeue_count: 1)
        stale_run.update_columns(updated_at: (claimed_threshold + 60).seconds.ago)

        described_class.perform_now

        stale_run.reload
        expect(stale_run.status).to eq("queued")
        expect(stale_run.stale_requeue_count).to eq(2)
      end

      it "cancels the existing Temporal workflow before requeuing" do
        stale_run = create(:agent_run, status: "queued",
          started_at: 5.minutes.ago,
          temporal_workflow_id: "queued-1-2-123456",
          temporal_run_id: "run-abc")
        stale_run.update_columns(updated_at: (claimed_threshold + 60).seconds.ago)

        handle = double(cancel: true) # rubocop:disable RSpec/VerifiedDoubles
        temporal_client = double(workflow_handle: handle) # rubocop:disable RSpec/VerifiedDoubles
        allow(Paid).to receive(:temporal_client).and_return(temporal_client)

        described_class.perform_now

        stale_run.reload
        expect(stale_run.status).to eq("queued")
        expect(stale_run.temporal_workflow_id).to be_nil
        expect(stale_run.temporal_run_id).to be_nil
        expect(handle).to have_received(:cancel)
      end

      it "clears service_environment when requeuing" do
        stale_run = create(:agent_run, status: "queued", temporal_workflow_id: "test-workflow-id", service_environment: { "DATABASE_URL" => "postgres://old" })
        stale_run.update_columns(updated_at: (claimed_threshold + 60).seconds.ago)

        described_class.perform_now

        stale_run.reload
        expect(stale_run.status).to eq("queued")
        expect(stale_run.service_environment).to be_nil
      end

      it "passes captured service environment to service cleanup when requeuing" do
        service_container = create(:service_container)
        old_environment = { "DATABASE_URL" => "postgres://agent:agent@pg:5432/agent_run_old_attempt_0" }
        stale_run = create(:agent_run, status: "queued", temporal_workflow_id: "test-workflow-id",
          service_container_ids: [ service_container.id ],
          service_environment: old_environment)
        stale_run.update_columns(updated_at: (claimed_threshold + 60).seconds.ago)
        provisioner = instance_double(Containers::ServiceProvisioner)

        allow(Containers::ServiceProvisioner).to receive(:new).and_return(provisioner)
        allow(provisioner).to receive(:cleanup) do |run, stale_requeue_count:|
          expect(run.service_container_ids).to eq([ service_container.id ])
          expect(run.service_environment).to eq(old_environment)
          expect(stale_requeue_count).to eq(0)
        end

        described_class.perform_now

        expect(provisioner).to have_received(:cleanup)
      end

      it "skips requeue when Temporal workflow cancel fails with non-NOT_FOUND error" do
        stale_run = create(:agent_run, status: "queued",
          started_at: 5.minutes.ago,
          temporal_workflow_id: "queued-1-2-123456")
        stale_run.update_columns(updated_at: (claimed_threshold + 60).seconds.ago)

        allow(Rails.logger).to receive(:warn)
        handle = double # rubocop:disable RSpec/VerifiedDoubles
        allow(handle).to receive(:cancel).and_raise(RuntimeError, "connection refused")
        temporal_client = double(workflow_handle: handle) # rubocop:disable RSpec/VerifiedDoubles
        allow(Paid).to receive(:temporal_client).and_return(temporal_client)

        described_class.perform_now

        stale_run.reload
        expect(stale_run.status).to eq("queued")
        expect(stale_run.stale_requeue_count).to eq(0)
        expect(stale_run.stale_skip_count).to eq(1)
        expect(Rails.logger).to have_received(:warn).with(hash_including(
          message: "stale_run_detector.skipped_stale_run",
          agent_run_id: stale_run.id,
          reason: "temporal_cancel_failed",
          stale_skip_count: 1
        ))
      end

      it "times out after repeated Temporal workflow cancel failures" do
        stale_run = create(:agent_run, status: "queued",
          started_at: 5.minutes.ago,
          temporal_workflow_id: "queued-1-2-123456",
          stale_skip_count: described_class::MAX_STALE_SKIPS - 1)
        stale_run.update_columns(updated_at: (claimed_threshold + 60).seconds.ago)

        handle = double # rubocop:disable RSpec/VerifiedDoubles
        allow(handle).to receive(:cancel).and_raise(RuntimeError, "connection refused")
        temporal_client = double(workflow_handle: handle) # rubocop:disable RSpec/VerifiedDoubles
        allow(Paid).to receive(:temporal_client).and_return(temporal_client)

        described_class.perform_now

        stale_run.reload
        expect(stale_run.status).to eq("timeout")
        expect(stale_run.stale_skip_count).to eq(described_class::MAX_STALE_SKIPS)
      end

      it "still cancels and requeues when only temporal_workflow_id is present" do
        stale_run = create(:agent_run, status: "queued",
          started_at: nil,
          temporal_workflow_id: "queued-1-2-123456")
        stale_run.update_columns(updated_at: (claimed_threshold + 60).seconds.ago)

        handle = double(cancel: true) # rubocop:disable RSpec/VerifiedDoubles
        temporal_client = double(workflow_handle: handle) # rubocop:disable RSpec/VerifiedDoubles
        allow(Paid).to receive(:temporal_client).and_return(temporal_client)

        described_class.perform_now

        stale_run.reload
        expect(stale_run.status).to eq("queued")
        expect(stale_run.temporal_workflow_id).to be_nil
        expect(handle).to have_received(:cancel)
      end

      it "still requeues when Temporal workflow cancel fails with not-found" do
        stale_run = create(:agent_run, status: "queued",
          started_at: 5.minutes.ago,
          temporal_workflow_id: "queued-1-2-123456",
          stale_skip_count: 1)
        stale_run.update_columns(updated_at: (claimed_threshold + 60).seconds.ago)

        error = Temporalio::Error::RPCError.allocate
        allow(error).to receive(:code).and_return(Temporalio::Error::RPCError::Code::NOT_FOUND)
        handle = double # rubocop:disable RSpec/VerifiedDoubles
        allow(handle).to receive(:cancel).and_raise(error)
        temporal_client = double(workflow_handle: handle) # rubocop:disable RSpec/VerifiedDoubles
        allow(Paid).to receive(:temporal_client).and_return(temporal_client)

        described_class.perform_now

        stale_run.reload
        expect(stale_run.status).to eq("queued")
        expect(stale_run.stale_skip_count).to eq(0)
      end
    end

    context "when GitHub circuit is open" do
      it "still resolves stale running runs" do
        create(:github_health_state, :circuit_open)

        stale_run = create(:agent_run, :running, started_at: (running_threshold + 60).seconds.ago)
        allow(Containers::ServiceProvisioner).to receive(:new)
          .and_return(instance_double(Containers::ServiceProvisioner, cleanup: nil))

        described_class.perform_now

        expect(stale_run.reload.status).to eq("timeout")
      end
    end

    context "with stale paused runs" do
      it "requeues a stale paused run that has not exhausted requeue budget" do
        stale_run = create(:agent_run, :paused, paused_at: (paused_threshold + 60).seconds.ago)

        described_class.perform_now

        stale_run.reload
        expect(stale_run.status).to eq("queued")
        expect(stale_run.stale_requeue_count).to eq(1)
        expect(stale_run.started_at).to be_nil
        expect(stale_run.paused_at).to be_nil
        expect(stale_run.guardrail_violation_type).to be_nil
        expect(stale_run.guardrail_context).to be_nil
      end

      it "does not touch paused runs within the threshold" do
        recent_run = create(:agent_run, :paused, paused_at: (paused_threshold - 60).seconds.ago)

        described_class.perform_now

        expect(recent_run.reload.status).to eq("paused")
      end

      it "times out a stale paused run that has exhausted requeue budget" do
        stale_run = create(:agent_run, :paused,
          paused_at: (paused_threshold + 60).seconds.ago,
          stale_requeue_count: described_class::MAX_STALE_REQUEUES)

        described_class.perform_now

        stale_run.reload
        expect(stale_run.status).to eq("timeout")
        expect(stale_run.error_message).to start_with(AgentRun::STALE_DETECTOR_ERROR_PREFIX)
      end

      it "times out a stale time-limit paused run with zero iterations" do
        stale_run = create(:agent_run, :paused,
          paused_at: (paused_threshold + 60).seconds.ago,
          guardrail_violation_type: "time_limit",
          guardrail_context: { violation_type: "time_limit" },
          iterations: 0)

        described_class.perform_now

        stale_run.reload
        expect(stale_run.status).to eq("timeout")
        expect(stale_run.stale_requeue_count).to eq(0)
        expect(stale_run.error_message).to start_with(AgentRun::STALE_DETECTOR_ERROR_PREFIX)
      end

      it "requeues a stale time-limit paused run that made progress" do
        stale_run = create(:agent_run, :paused,
          paused_at: (paused_threshold + 60).seconds.ago,
          guardrail_violation_type: "time_limit",
          guardrail_context: { violation_type: "time_limit" },
          iterations: 1)

        described_class.perform_now

        stale_run.reload
        expect(stale_run.status).to eq("queued")
        expect(stale_run.stale_requeue_count).to eq(1)
      end
    end

    context "with orphaned in_progress issues" do
      let(:project) { create(:project) }

      it "resets an orphaned in_progress issue to new when no active run exists" do
        issue = create(:issue, project: project, paid_state: "in_progress",
          updated_at: (described_class::ORPHANED_IN_PROGRESS_AGE + 5.minutes).ago)

        described_class.perform_now

        expect(issue.reload.paid_state).to eq("new")
      end

      it "does not reset an in_progress issue that has an active run" do
        issue = create(:issue, project: project, paid_state: "in_progress",
          updated_at: (described_class::ORPHANED_IN_PROGRESS_AGE + 5.minutes).ago)
        create(:agent_run, :running, project: project, issue: issue)

        described_class.perform_now

        expect(issue.reload.paid_state).to eq("in_progress")
      end

      it "does not reset an orphaned enhance_issue recheck before its run is queued" do
        issue = create(:issue,
          project: project,
          paid_state: "in_progress",
          enhance_issue_rounds: 1,
          labels: [],
          updated_at: (described_class::ORPHANED_IN_PROGRESS_AGE + 5.minutes).ago)
        create(:agent_run, :completed, :enhance_issue_goal, project: project, issue: issue, pull_request_number: nil)

        described_class.perform_now

        expect(issue.reload.paid_state).to eq("in_progress")
      end

      it "still resets a non-enhancement orphan with prior enhance_issue history" do
        issue = create(:issue,
          project: project,
          paid_state: "in_progress",
          enhance_issue_rounds: 1,
          labels: [ project.enhance_issue_enhanced_label_name ],
          updated_at: (described_class::ORPHANED_IN_PROGRESS_AGE + 5.minutes).ago)
        create(:agent_run, :completed, :enhance_issue_goal, project: project, issue: issue, pull_request_number: nil)

        described_class.perform_now

        expect(issue.reload.paid_state).to eq("new")
      end

      it "does not reset an issue whose paid_state changed before lock acquisition" do
        issue = create(:issue, project: project, paid_state: "in_progress",
          updated_at: (described_class::ORPHANED_IN_PROGRESS_AGE + 5.minutes).ago)

        issue.update_column(:paid_state, "completed")

        described_class.perform_now

        expect(issue.reload.paid_state).to eq("completed")
      end

      it "does not reset an issue that gets a new run between query and lock" do
        issue = create(:issue, project: project, paid_state: "in_progress",
          updated_at: (described_class::ORPHANED_IN_PROGRESS_AGE + 5.minutes).ago)

        allow(AgentRun).to receive(:where).and_call_original
        allow(AgentRun).to receive(:where).with(
          hash_including(issue: issue)
        ).and_return(double(exists?: true))

        described_class.perform_now

        expect(issue.reload.paid_state).to eq("in_progress")
      end

      it "does not reset a recently updated in_progress issue" do
        issue = create(:issue, project: project, paid_state: "in_progress",
          updated_at: 1.minute.ago)

        described_class.perform_now

        expect(issue.reload.paid_state).to eq("in_progress")
      end

      it "resets an orphaned in_progress PR to completed when no active run exists" do
        pull_request = create(:issue, :pull_request, project: project, paid_state: "in_progress",
          updated_at: (described_class::ORPHANED_IN_PROGRESS_AGE + 5.minutes).ago)

        described_class.perform_now

        expect(pull_request.reload.paid_state).to eq("completed")
      end

      it "does not reset an in_progress PR that has an active run" do
        pull_request = create(:issue, :pull_request, project: project, paid_state: "in_progress",
          updated_at: (described_class::ORPHANED_IN_PROGRESS_AGE + 5.minutes).ago)
        create(:agent_run, :running, project: project, issue: pull_request)

        described_class.perform_now

        expect(pull_request.reload.paid_state).to eq("in_progress")
      end

      it "enqueues ProcessRunQueueJob after recovering orphans" do
        create(:issue, project: project, paid_state: "in_progress",
          updated_at: (described_class::ORPHANED_IN_PROGRESS_AGE + 5.minutes).ago)

        expect(ProcessRunQueueJob).to receive(:perform_later).and_call_original

        described_class.perform_now
      end
    end

    context "with rate-limited runs due for recovery" do
      let(:project) { create(:project) }

      it "re-queues a rate-limited run whose recovery window has elapsed" do
        run = create(:agent_run, :rate_limited, rate_limited_until: 1.minute.ago)

        described_class.perform_now

        run.reload
        expect(run.status).to eq("queued")
        expect(run.rate_limited_until).to be_nil
        expect(run.stale_requeue_count).to eq(1)
      end

      it "does not touch a rate-limited run whose recovery window is in the future" do
        run = create(:agent_run, :rate_limited, rate_limited_until: 5.minutes.from_now)

        described_class.perform_now

        expect(run.reload.status).to eq("rate_limited")
      end

      it "leaves the issue in_progress when re-queuing (does not arm re-enqueue)" do
        issue = create(:issue, :in_progress, project: project)
        create(:agent_run, :rate_limited, project: project, issue: issue, rate_limited_until: 1.minute.ago)

        described_class.perform_now

        expect(issue.reload.paid_state).to eq("in_progress")
      end

      it "terminally fails a rate-limited run that exhausts its requeue budget" do
        issue = create(:issue, :in_progress, project: project)
        run = create(:agent_run, :rate_limited, project: project, issue: issue,
          rate_limited_until: 1.minute.ago,
          stale_requeue_count: AgentRun::MAX_RATE_LIMITED_REQUEUES)

        described_class.perform_now

        expect(run.reload.status).to eq("failed")
        expect(issue.reload.paid_state).to eq("failed")
      end

      it "restores the issue to completed (not failed) when an exhausted run is a review goal" do
        issue = create(:issue, :in_progress, :pull_request, project: project)
        run = create(:agent_run, :rate_limited, :review_goal, project: project, issue: issue,
          rate_limited_until: 1.minute.ago,
          stale_requeue_count: AgentRun::MAX_RATE_LIMITED_REQUEUES)

        described_class.perform_now

        expect(run.reload.status).to eq("failed")
        expect(issue.reload.paid_state).to eq("completed")
      end

      it "does not let orphan recovery reset an issue whose run awaits a future recovery window" do
        issue = create(:issue, :in_progress, project: project,
          updated_at: (described_class::ORPHANED_IN_PROGRESS_AGE + 5.minutes).ago)
        run = create(:agent_run, :rate_limited, project: project, issue: issue,
          rate_limited_until: 30.minutes.from_now)

        described_class.perform_now

        # The run is still waiting; orphan recovery must NOT yank the issue to
        # "new" (which would mint a duplicate, superseding run).
        expect(issue.reload.paid_state).to eq("in_progress")
        expect(run.reload.status).to eq("rate_limited")
      end

      it "fails the run when an active sibling already owns the issue" do
        issue = create(:issue, :in_progress, project: project)
        rate_limited = create(:agent_run, :rate_limited, project: project, issue: issue,
          goal: "create_pr", rate_limited_until: 1.minute.ago)
        # An active (queued) run already holds the unique active-issue slot.
        create(:agent_run, :queued, project: project, issue: issue, goal: "create_pr")

        described_class.perform_now

        expect(rate_limited.reload.status).to eq("failed")
        expect(rate_limited.error_message).to include("Superseded by another active run")
      end
    end
  end
end
