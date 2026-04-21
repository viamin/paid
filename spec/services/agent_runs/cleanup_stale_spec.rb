# frozen_string_literal: true

require "rails_helper"

RSpec.describe AgentRuns::CleanupStale do
  describe ".call" do
    let(:project) { create(:project) }

    it "times out stale running runs for the project" do
      stale_run = create(:agent_run, :running, project: project, started_at: AgentRun.stale_running_cutoff - 1.minute)

      described_class.call(project: project)

      expect(stale_run.reload.status).to eq("timeout")
      expect(stale_run.error_message).to eq("Manual stale run cleanup: exceeded running timeout")
    end

    it "requeues stale pending runs for the project" do
      stale_run = create(:agent_run, status: "pending", project: project)
      stale_run.update_column(:updated_at, AgentRun.stale_pending_cutoff - 1.minute)

      described_class.call(project: project)

      stale_run.reload
      expect(stale_run.status).to eq("queued")
      expect(stale_run.stale_requeue_count).to eq(1)
      expect(stale_run.temporal_workflow_id).to be_nil
      expect(stale_run.temporal_run_id).to be_nil
    end

    it "times out stale pending runs that exhausted the requeue budget" do
      stale_run = create(:agent_run, status: "pending", project: project, stale_requeue_count: AgentRun::MAX_STALE_REQUEUES)
      stale_run.update_column(:updated_at, AgentRun.stale_pending_cutoff - 1.minute)

      described_class.call(project: project)

      expect(stale_run.reload.status).to eq("timeout")
      expect(stale_run.error_message).to eq("Manual stale run cleanup: exceeded pending requeue limit")
    end

    it "leaves fresh or non-stale runs untouched" do
      fresh_run = create(:agent_run, :running, project: project, started_at: AgentRun.stale_running_cutoff + 1.minute)
      pending_run = create(:agent_run, status: "pending", project: project)
      pending_run.update_column(:updated_at, AgentRun.stale_pending_cutoff + 1.minute)

      described_class.call(project: project)

      expect(fresh_run.reload.status).to eq("running")
      expect(pending_run.reload.status).to eq("pending")
    end

    it "cleans up run and service containers" do
      stale_run = create(:agent_run, :running, project: project,
        started_at: AgentRun.stale_running_cutoff - 1.minute,
        container_id: "container-123",
        service_container_ids: [ 1, 2 ])
      relation = instance_double(ActiveRecord::Relation)
      container_service = instance_double(Containers::Provision, cleanup: true)
      provisioner = instance_double(Containers::ServiceProvisioner, cleanup: true)

      allow(project.agent_runs).to receive(:stale_for_cleanup).and_return(relation)
      allow(relation).to receive(:find_each).and_yield(stale_run)
      allow(Containers::Provision).to receive(:reconnect).and_return(container_service)
      allow(Containers::ServiceProvisioner).to receive(:new).and_return(provisioner)

      described_class.call(project: project)

      expect(container_service).to have_received(:cleanup).with(force: true)
      expect(provisioner).to have_received(:cleanup).with(stale_run, stale_requeue_count: 0)
    end

    it "passes captured service environment to service cleanup when requeuing pending runs" do
      service_container = create(:service_container)
      old_environment = { "DATABASE_URL" => "postgres://agent:agent@pg:5432/agent_run_old_attempt_0" }
      stale_run = create(:agent_run, status: "pending", project: project,
        service_container_ids: [ service_container.id ],
        service_environment: old_environment)
      stale_run.update_column(:updated_at, AgentRun.stale_pending_cutoff - 1.minute)
      provisioner = instance_double(Containers::ServiceProvisioner)

      allow(Containers::ServiceProvisioner).to receive(:new).and_return(provisioner)
      allow(provisioner).to receive(:cleanup) do |run, stale_requeue_count:|
        expect(run.service_container_ids).to eq([ service_container.id ])
        expect(run.service_environment).to eq(old_environment)
        expect(stale_requeue_count).to eq(0)
      end

      described_class.call(project: project)

      expect(provisioner).to have_received(:cleanup)
    end

    it "updates the issue paid state and re-enqueues the run queue" do
      stale_run = create(:agent_run, :running, project: project, started_at: AgentRun.stale_running_cutoff - 1.minute)
      stale_run.issue.update!(paid_state: "in_progress")

      expect {
        described_class.call(project: project)
      }.to have_enqueued_job(ProcessRunQueueJob)

      expect(stale_run.issue.reload.paid_state).to eq("failed")
    end

    it "clears container_id even when Docker reconnect fails" do
      stale_run = create(:agent_run, :running, project: project,
        started_at: AgentRun.stale_running_cutoff - 1.minute,
        container_id: "container-gone")
      relation = instance_double(ActiveRecord::Relation)
      provisioner = instance_double(Containers::ServiceProvisioner, cleanup: true)

      allow(project.agent_runs).to receive(:stale_for_cleanup).and_return(relation)
      allow(relation).to receive(:find_each).and_yield(stale_run)
      allow(Containers::Provision).to receive(:reconnect).and_raise(Docker::Error::NotFoundError, "container gone")
      allow(Containers::ServiceProvisioner).to receive(:new).and_return(provisioner)

      described_class.call(project: project)

      expect(stale_run.reload.container_id).to be_nil
    end

    it "clears container_id even when Docker cleanup fails" do
      stale_run = create(:agent_run, :running, project: project,
        started_at: AgentRun.stale_running_cutoff - 1.minute,
        container_id: "container-broken")
      relation = instance_double(ActiveRecord::Relation)
      container_service = instance_double(Containers::Provision)
      provisioner = instance_double(Containers::ServiceProvisioner, cleanup: true)

      allow(container_service).to receive(:cleanup).and_raise(Docker::Error::ServerError, "cleanup failed")
      allow(project.agent_runs).to receive(:stale_for_cleanup).and_return(relation)
      allow(relation).to receive(:find_each).and_yield(stale_run)
      allow(Containers::Provision).to receive(:reconnect).and_return(container_service)
      allow(Containers::ServiceProvisioner).to receive(:new).and_return(provisioner)

      described_class.call(project: project)

      expect(stale_run.reload.container_id).to be_nil
    end

    it "returns the number of cleaned runs" do
      create(:agent_run, :running, project: project, started_at: AgentRun.stale_running_cutoff - 1.minute)
      stale_pending = create(:agent_run, status: "pending", project: project)
      stale_pending.update_column(:updated_at, AgentRun.stale_pending_cutoff - 1.minute)

      expect(described_class.call(project: project)).to eq(2)
    end
  end
end
