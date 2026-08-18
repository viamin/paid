# frozen_string_literal: true

require "rails_helper"

# @spec CONTAINER-RUNTIME-020
RSpec.describe ExecutionResource do
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
end
