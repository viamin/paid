# frozen_string_literal: true

require "rails_helper"

# @spec CONTAINER-RUNTIME-030
RSpec.describe ExecutionResource do
  describe "#mark_cleanup_pending!" do
    let(:project) { create(:project) }
    let(:agent_run) { create(:agent_run, :completed, project: project) }
    let(:resource) { create(:execution_resource, project: project, agent_run: agent_run) }

    it "defaults next_cleanup_at into the future on first transition" do
      resource.mark_cleanup_pending!

      expect(resource.reload).to have_attributes(
        state: "cleanup_pending",
        cleaned_at: nil
      )
      # A future offset closes the race window with the cron reconciler: while
      # AgentRun#cleanup_container / AgentRunResourceJanitorJob are between
      # schedule_cleanup_for! and mark_cleaned_for!, the reconciler would
      # otherwise re-enter provider cleanup against an already-in-flight call.
      expect(resource.next_cleanup_at).to be > Time.current
      expect(resource.next_cleanup_at).to be <= Time.current + described_class::CLEANUP_BASE_DELAY + 1.second
    end

    it "preserves an existing next_cleanup_at set by a prior failure" do
      resource.update!(
        state: "cleanup_pending",
        next_cleanup_at: 30.minutes.from_now,
        cleanup_attempts: 2
      )

      resource.mark_cleanup_pending!

      # record_cleanup_failure! already wrote a future backoff — preserve it
      # instead of resetting the schedule on every transition.
      expect(resource.reload.next_cleanup_at).to be_within(1.second).of(30.minutes.from_now)
    end
  end

  describe "project deletion" do
    it "nullifies rather than blocking project destroy, since ledger rows are designed to outlive their runs" do
      project = create(:project)
      agent_run = create(:agent_run, :completed, project: project)
      resource = create(:execution_resource, project: project, agent_run: agent_run, state: "cleaned")

      expect { project.destroy! }.not_to raise_error

      expect(resource.reload).to have_attributes(project_id: nil, agent_run_id: nil)
    end
  end

  describe ".track_environment!" do
    let(:project) { create(:project) }
    let(:agent_run) { create(:agent_run, :running, project: project) }
    let!(:resource) do
      create(:execution_resource,
        project: project,
        agent_run: agent_run,
        state: "cleanup_pending",
        cleanup_attempts: 2,
        next_cleanup_at: 2.hours.from_now,
        last_cleanup_error: "daemon unavailable",
        last_cleanup_error_class: "Docker::Error::DockerError",
        last_cleanup_failed_at: 5.minutes.ago,
        reduced_confidence: true)
    end
    let(:handle) do
      ExecutionRunners::RunnerHandle.new(
        runner_type: :local_docker,
        identifier: "replacement-container",
        host: "remote",
        workspace_ref: "paid-workspace-#{agent_run.id}",
        metadata: {
          "agent_run_id" => agent_run.id,
          "worktree_path" => agent_run.worktree_path,
          "environment" => {}
        }
      )
    end

    it "returns nil when the run id cannot be read yet" do
      agent_run = Object.new
      agent_run.define_singleton_method(:id) { raise NoMethodError, "not initialized" }

      expect(described_class.track_environment!(agent_run: agent_run)).to be_nil
    end

    it "reactivates a previously cleanup-pending environment and clears stale retry metadata" do
      described_class.track_environment!(agent_run: agent_run, handle: handle)

      expect(resource.reload).to have_attributes(
        state: "active",
        identifier: "replacement-container",
        host: "remote",
        cleanup_attempts: 0,
        next_cleanup_at: nil,
        last_cleanup_error: nil,
        last_cleanup_error_class: nil,
        last_cleanup_failed_at: nil,
        reduced_confidence: false
      )
    end
  end

  describe ".schedule_cleanup_for!" do
    let(:project) { create(:project) }
    let(:agent_run) { create(:agent_run, :completed, project: project) }

    it "is a no-op for a run whose ledger row is already cleaned" do
      cleaned_at = 10.minutes.ago
      resource = create(:execution_resource,
        project: project,
        agent_run: agent_run,
        state: "cleaned",
        cleaned_at: cleaned_at)

      described_class.schedule_cleanup_for!(agent_run: agent_run)

      expect(resource.reload).to have_attributes(state: "cleaned")
      expect(resource.cleaned_at).to be_within(1.second).of(cleaned_at)
    end

    it "transitions an active resource to cleanup_pending" do
      resource = create(:execution_resource, project: project, agent_run: agent_run, state: "active")

      described_class.schedule_cleanup_for!(agent_run: agent_run)

      expect(resource.reload.state).to eq("cleanup_pending")
    end
  end
end
