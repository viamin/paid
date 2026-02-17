# frozen_string_literal: true

require "rails_helper"

RSpec.describe Containers::GitOperations do
  let(:project) { create(:project) }
  let(:agent_run) { create(:agent_run, :running, project: project) }
  let(:container_service) { instance_double(Containers::Provision) }
  let(:git_ops) { described_class.new(container_service: container_service, agent_run: agent_run) }

  let(:success_result) { Containers::Provision::Result.success(stdout: "", stderr: "", exit_code: 0) }
  let(:failure_result) { Containers::Provision::Result.failure(error: "git failed", stdout: "", stderr: "error", exit_code: 1) }

  describe "#clone_and_setup_branch" do
    let(:head_sha) { "abc123def456789012345678901234567890abcd" }
    let(:not_a_repo_result) { Containers::Provision::Result.failure(error: "not a git repo", stdout: "", stderr: "fatal: not a git repository", exit_code: 128) }

    before do
      allow(container_service).to receive(:execute).and_return(success_result)

      # The clone is skipped when rev-parse succeeds (idempotency guard),
      # so return failure to indicate /workspace is not yet a repo.
      allow(container_service).to receive(:execute)
        .with([ "git", "rev-parse", "--is-inside-work-tree" ], timeout: nil, stream: false)
        .and_return(not_a_repo_result)

      sha_result = Containers::Provision::Result.success(stdout: "#{head_sha}\n", stderr: "", exit_code: 0)
      allow(container_service).to receive(:execute)
        .with([ "git", "rev-parse", "HEAD" ], timeout: nil, stream: false)
        .and_return(sha_result)
    end

    it "clones the repository inside the container" do
      expect(container_service).to receive(:execute)
        .with([ "git", "clone", "https://github.com/#{project.full_name}.git", "." ],
              timeout: 120, stream: false)
        .and_return(success_result)

      git_ops.clone_and_setup_branch
    end

    it "creates a branch with a slug from the issue title when issue is present" do
      issue = create(:issue, project: project, title: "Fix login bug")
      agent_run.update!(issue: issue)

      git_ops.clone_and_setup_branch

      expect(agent_run.reload.branch_name).to match(/\Apaid\/#{issue.github_number}-fix-login-bug-[0-9a-f]{6}\z/)
    end

    it "creates a branch with a slug from custom_prompt when no issue" do
      agent_run.update!(issue: nil, custom_prompt: "Add dark mode toggle")

      git_ops.clone_and_setup_branch

      expect(agent_run.reload.branch_name).to match(/\Apaid\/add-dark-mode-toggle-[0-9a-f]{6}\z/)
    end

    it "falls back to agent ID when neither issue nor custom_prompt" do
      agent_run.update!(issue: nil, custom_prompt: "placeholder")
      agent_run.update_column(:custom_prompt, nil)

      git_ops.clone_and_setup_branch

      expect(agent_run.reload.branch_name).to match(/\Apaid\/agent-#{agent_run.id}-[0-9a-f]{6}\z/)
    end

    it "truncates long titles to keep branch names reasonable" do
      issue = create(:issue, project: project, title: "A very long issue title that should be truncated to keep branch names reasonable length")
      agent_run.update!(issue: issue)

      git_ops.clone_and_setup_branch

      branch = agent_run.reload.branch_name
      slug_part = branch.sub("paid/", "").sub(/-[0-9a-f]{6}\z/, "")
      expect(slug_part.length).to be <= 55 # number + "-" + 50 char slug
    end

    it "records the base commit SHA" do
      git_ops.clone_and_setup_branch

      expect(agent_run.reload.base_commit_sha).to eq(head_sha)
    end

    it "sets worktree_path to /workspace" do
      git_ops.clone_and_setup_branch

      expect(agent_run.reload.worktree_path).to eq("/workspace")
    end

    it "raises CloneError when clone fails" do
      allow(container_service).to receive(:execute)
        .with(array_including("clone"), anything)
        .and_return(failure_result)

      expect { git_ops.clone_and_setup_branch }.to raise_error(described_class::CloneError)
    end
  end

  describe "#push_branch" do
    let(:head_sha) { "def456789012345678901234567890abcdef1234" }

    before do
      agent_run.update!(branch_name: "paid/test-branch")
      create(:worktree, project: project, agent_run: agent_run, branch_name: "paid/test-branch", status: "active")

      allow(container_service).to receive(:execute)
        .with([ "git", "push", "origin", "paid/test-branch" ], timeout: 60, stream: false)
        .and_return(success_result)

      sha_result = Containers::Provision::Result.success(stdout: "#{head_sha}\n", stderr: "", exit_code: 0)
      allow(container_service).to receive(:execute)
        .with([ "git", "rev-parse", "HEAD" ], timeout: nil, stream: false)
        .and_return(sha_result)
    end

    it "pushes the branch and returns the commit SHA" do
      result = git_ops.push_branch

      expect(result).to eq(head_sha)
    end

    it "updates the agent run with the result commit SHA" do
      git_ops.push_branch

      expect(agent_run.reload.result_commit_sha).to eq(head_sha)
    end

    it "marks the worktree as pushed" do
      git_ops.push_branch

      expect(agent_run.worktree.reload).to be_pushed
    end

    it "raises PushError when branch_name is blank" do
      agent_run.update!(branch_name: nil)

      expect { git_ops.push_branch }.to raise_error(described_class::PushError, /branch_name is blank/)
    end

    it "raises PushError when push fails" do
      allow(container_service).to receive(:execute)
        .with(array_including("push"), anything)
        .and_return(failure_result)

      expect { git_ops.push_branch }.to raise_error(described_class::PushError)
    end
  end

  describe "#has_changes?" do
    let(:base_sha) { "abc123def456" }

    it "returns true when there are committed changes vs base" do
      agent_run.update!(base_commit_sha: base_sha)
      diff_result = Containers::Provision::Result.success(stdout: " file.rb | 2 +-\n 1 file changed", stderr: "", exit_code: 0)
      allow(container_service).to receive(:execute)
        .with([ "git", "diff", "--stat", base_sha, "HEAD" ], timeout: nil, stream: false)
        .and_return(diff_result)

      expect(git_ops.has_changes?).to be true
    end

    it "returns false when there are no changes vs base" do
      agent_run.update!(base_commit_sha: base_sha)
      diff_result = Containers::Provision::Result.success(stdout: "", stderr: "", exit_code: 0)
      allow(container_service).to receive(:execute)
        .with([ "git", "diff", "--stat", base_sha, "HEAD" ], timeout: nil, stream: false)
        .and_return(diff_result)

      expect(git_ops.has_changes?).to be false
    end

    it "falls back to diffing HEAD when base_commit_sha is blank" do
      agent_run.update_column(:base_commit_sha, nil)
      diff_result = Containers::Provision::Result.success(stdout: "", stderr: "", exit_code: 0)
      allow(container_service).to receive(:execute)
        .with([ "git", "diff", "--stat", "HEAD" ], timeout: nil, stream: false)
        .and_return(diff_result)

      expect(git_ops.has_changes?).to be false
    end

    it "returns false on error" do
      allow(container_service).to receive(:execute).and_raise(StandardError, "container gone")

      expect(git_ops.has_changes?).to be false
    end
  end
end
