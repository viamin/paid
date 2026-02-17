# frozen_string_literal: true

require "rails_helper"

RSpec.describe Activities::CloneRepoActivity do
  let(:project) { create(:project) }
  let(:agent_run) { create(:agent_run, :running, project: project, container_id: "abc123") }
  let(:activity) { described_class.new }
  let(:container_service) { instance_double(Containers::Provision) }
  let(:git_ops) { instance_double(Containers::GitOperations) }

  describe "#execute" do
    before do
      allow(Containers::Provision).to receive(:reconnect)
        .with(agent_run: agent_run, container_id: "abc123")
        .and_return(container_service)
      allow(Containers::GitOperations).to receive(:new)
        .with(container_service: container_service, agent_run: agent_run)
        .and_return(git_ops)
      allow(git_ops).to receive(:clone_and_setup_branch)

      # Simulate what clone_and_setup_branch does to agent_run
      agent_run.update!(
        branch_name: "paid/paid-agent-#{agent_run.id}-20260215-abc123",
        base_commit_sha: "abc123def456",
        worktree_path: "/workspace"
      )
    end

    it "clones the repo and creates a worktree record" do
      expect(git_ops).to receive(:clone_and_setup_branch)

      result = activity.execute(agent_run_id: agent_run.id)

      expect(result[:agent_run_id]).to eq(agent_run.id)
      expect(result[:branch_name]).to eq(agent_run.branch_name)
      expect(Worktree.find_by(agent_run: agent_run)).to be_present
    end

    it "raises ActiveRecord::RecordNotFound for invalid agent_run_id" do
      expect { activity.execute(agent_run_id: -1) }.to raise_error(ActiveRecord::RecordNotFound)
    end
  end
end
