# frozen_string_literal: true

require "rails_helper"

RSpec.describe Activities::PushBranchActivity do
  let(:project) { create(:project) }
  let(:agent_run) { create(:agent_run, :with_git_context, :running, project: project, container_id: "abc123") }
  let(:activity) { described_class.new }
  let(:commit_sha) { "abc123def456789012345678901234567890abcd" }
  let(:container_service) { instance_double(Containers::Provision) }
  let(:git_ops) { instance_double(Containers::GitOperations) }

  describe "#execute" do
    it "pushes the branch inside the container and returns commit SHA" do
      allow(Containers::Provision).to receive(:reconnect)
        .with(agent_run: agent_run, container_id: "abc123")
        .and_return(container_service)
      allow(Containers::GitOperations).to receive(:new)
        .with(container_service: container_service, agent_run: agent_run)
        .and_return(git_ops)
      expect(git_ops).to receive(:push_branch).and_return(commit_sha)

      result = activity.execute(agent_run_id: agent_run.id)

      expect(result[:commit_sha]).to eq(commit_sha)
      expect(result[:agent_run_id]).to eq(agent_run.id)
    end

    it "raises ActiveRecord::RecordNotFound for invalid agent_run_id" do
      expect { activity.execute(agent_run_id: -1) }.to raise_error(ActiveRecord::RecordNotFound)
    end
  end
end
