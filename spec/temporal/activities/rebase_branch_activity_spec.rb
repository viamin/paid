# frozen_string_literal: true

require "rails_helper"
require "ostruct"

RSpec.describe Activities::RebaseBranchActivity do
  let(:project) { create(:project) }
  let(:agent_run) do
    create(:agent_run, :running,
      project: project,
      source_pull_request_number: 42,
      custom_prompt: "Fix PR")
  end
  let(:container_service) { instance_double(Containers::Provision) }
  let(:github_client) { instance_double(GithubClient) }
  let(:activity) { described_class.new }

  let(:pr_data) do
    OpenStruct.new(
      base: OpenStruct.new(ref: "main"),
      head: OpenStruct.new(ref: "fix-branch", sha: "abc123")
    )
  end

  before do
    agent_run.update!(container_id: "container-123")

    allow(Containers::Provision).to receive(:reconnect).and_return(container_service)
    allow(GithubClient).to receive(:new).and_return(github_client)

    allow(github_client).to receive(:pull_request)
      .with(project.full_name, 42)
      .and_return(pr_data)
  end

  describe "#execute" do
    context "when rebase succeeds" do
      before do
        success_result = Containers::Provision::Result.success(stdout: "", stderr: "", exit_code: 0)
        allow(container_service).to receive(:execute).and_return(success_result)
      end

      it "returns rebase_succeeded: true" do
        result = activity.execute(agent_run_id: agent_run.id)

        expect(result[:rebase_succeeded]).to be true
        expect(result[:base_branch]).to eq("main")
        expect(result[:agent_run_id]).to eq(agent_run.id)
      end

      it "fetches the base branch from the PR" do
        expect(github_client).to receive(:pull_request)
          .with(project.full_name, 42)
          .and_return(pr_data)

        activity.execute(agent_run_id: agent_run.id)
      end
    end

    context "when rebase has conflicts" do
      before do
        success_result = Containers::Provision::Result.success(stdout: "", stderr: "", exit_code: 0)
        conflict_result = Containers::Provision::Result.failure(
          error: "rebase failed",
          stdout: "",
          stderr: "CONFLICT (content): Merge conflict in file.rb",
          exit_code: 1
        )

        # fetch succeeds
        allow(container_service).to receive(:execute)
          .with([ "git", "fetch", "origin", "main" ], timeout: nil, stream: false)
          .and_return(success_result)

        # rebase fails with conflict
        allow(container_service).to receive(:execute)
          .with([ "git", "rebase", "origin/main" ], timeout: nil, stream: false)
          .and_return(conflict_result)

        # abort succeeds
        allow(container_service).to receive(:execute)
          .with([ "git", "rebase", "--abort" ], timeout: nil, stream: false)
          .and_return(success_result)
      end

      it "returns rebase_succeeded: false" do
        result = activity.execute(agent_run_id: agent_run.id)

        expect(result[:rebase_succeeded]).to be false
        expect(result[:base_branch]).to eq("main")
      end
    end
  end
end
