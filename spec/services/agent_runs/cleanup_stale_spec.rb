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

    it "leaves fresh or non-running runs untouched" do
      fresh_run = create(:agent_run, :running, project: project, started_at: AgentRun.stale_running_cutoff + 1.minute)
      pending_run = create(:agent_run, status: "pending", project: project, started_at: AgentRun.stale_running_cutoff - 1.minute)

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
      agent_runs = double(stale_running: relation)
      provisioner = instance_double(Containers::ServiceProvisioner, cleanup: true)

      allow(project).to receive(:agent_runs).and_return(agent_runs)
      allow(relation).to receive(:find_each).and_yield(stale_run)
      allow(Containers::ServiceProvisioner).to receive(:new).and_return(provisioner)
      expect(stale_run).to receive(:cleanup_container).with(force: true)

      described_class.call(project: project)

      expect(provisioner).to have_received(:cleanup).with(stale_run)
    end

    it "updates the issue paid state and re-enqueues the run queue" do
      stale_run = create(:agent_run, :running, project: project, started_at: AgentRun.stale_running_cutoff - 1.minute)
      stale_run.issue.update!(paid_state: "in_progress")

      expect {
        described_class.call(project: project)
      }.to have_enqueued_job(ProcessRunQueueJob)

      expect(stale_run.issue.reload.paid_state).to eq("failed")
    end

    it "returns the number of cleaned runs" do
      create(:agent_run, :running, project: project, started_at: AgentRun.stale_running_cutoff - 1.minute)
      create(:agent_run, :running, project: project, started_at: AgentRun.stale_running_cutoff - 2.minutes)

      expect(described_class.call(project: project)).to eq(2)
    end
  end
end
