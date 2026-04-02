# frozen_string_literal: true

require "rails_helper"
require "ostruct"

RSpec.describe Activities::AggregateBranchesActivity do
  let(:activity) { described_class.new }
  let(:project) { create(:project) }
  let(:client) { instance_double(GithubClient) }
  let(:github_token) { instance_double(GithubToken, client: client) }
  let(:base_ref) { OpenStruct.new(object: OpenStruct.new(sha: "abc123")) }

  before do
    allow(Project).to receive(:find).with(project.id).and_return(project)
    allow(project).to receive(:github_token).and_return(github_token)
    allow(client).to receive(:ref).and_return(base_ref)
    allow(client).to receive(:create_ref)
  end

  describe "#execute" do
    it "creates a feature branch from the default branch" do
      allow(client).to receive(:merge)

      agent_run = create(:agent_run, project: project, branch_name: "sub-task-1")

      activity.execute(
        project_id: project.id,
        results: [ { success: true, agent_run_id: agent_run.id } ],
        feature_branch_name: "feature/aggregated-test"
      )

      expect(client).to have_received(:create_ref)
        .with(project.full_name, "refs/heads/feature/aggregated-test", "abc123")
    end

    it "merges successful sub-task branches into the feature branch" do
      allow(client).to receive(:merge)

      run1 = create(:agent_run, project: project, branch_name: "branch-1")
      run2 = create(:agent_run, project: project, branch_name: "branch-2")

      result = activity.execute(
        project_id: project.id,
        results: [
          { success: true, agent_run_id: run1.id },
          { success: true, agent_run_id: run2.id }
        ],
        feature_branch_name: "feature/test"
      )

      expect(result[:merged_branches]).to contain_exactly("branch-1", "branch-2")
      expect(result[:failed_merges]).to be_empty
      expect(client).to have_received(:merge).twice
    end

    it "skips failed sub-tasks" do
      allow(client).to receive(:merge)

      run1 = create(:agent_run, project: project, branch_name: "branch-1")

      result = activity.execute(
        project_id: project.id,
        results: [
          { success: true, agent_run_id: run1.id },
          { success: false, agent_run_id: nil }
        ],
        feature_branch_name: "feature/test"
      )

      expect(result[:merged_branches]).to eq([ "branch-1" ])
      expect(client).to have_received(:merge).once
    end

    it "skips agent runs without a branch name" do
      allow(client).to receive(:merge)

      run1 = create(:agent_run, project: project, branch_name: nil)

      result = activity.execute(
        project_id: project.id,
        results: [ { success: true, agent_run_id: run1.id } ],
        feature_branch_name: "feature/test"
      )

      expect(result[:merged_branches]).to be_empty
      expect(client).not_to have_received(:merge)
    end

    it "records merge conflict failures gracefully" do
      run1 = create(:agent_run, project: project, branch_name: "branch-1")
      run2 = create(:agent_run, project: project, branch_name: "branch-2")

      call_count = 0
      allow(client).to receive(:merge) do |*_args, **_kwargs|
        call_count += 1
        raise GithubClient::ApiError.new("Merge conflict", status: 409) if call_count == 2
      end

      result = activity.execute(
        project_id: project.id,
        results: [
          { success: true, agent_run_id: run1.id },
          { success: true, agent_run_id: run2.id }
        ],
        feature_branch_name: "feature/test"
      )

      expect(result[:merged_branches]).to eq([ "branch-1" ])
      expect(result[:failed_merges]).to eq([ { branch: "branch-2", error: "Merge conflict" } ])
    end

    it "re-raises non-conflict API errors" do
      run1 = create(:agent_run, project: project, branch_name: "branch-1")

      allow(client).to receive(:merge)
        .and_raise(GithubClient::ApiError.new("Rate limited", status: 403))

      expect {
        activity.execute(
          project_id: project.id,
          results: [ { success: true, agent_run_id: run1.id } ],
          feature_branch_name: "feature/test"
        )
      }.to raise_error(GithubClient::ApiError, "Rate limited")
    end

    it "returns the feature branch name" do
      result = activity.execute(
        project_id: project.id,
        results: [],
        feature_branch_name: "feature/my-branch"
      )

      expect(result[:feature_branch]).to eq("feature/my-branch")
    end
  end
end
