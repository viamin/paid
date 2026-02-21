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

  describe "#clone_and_checkout_branch" do
    let(:head_sha) { "abc123def456789012345678901234567890abcd" }
    let(:merge_base_sha) { "fff000fff000fff000fff000fff000fff000fff0" }
    let(:not_a_repo_result) { Containers::Provision::Result.failure(error: "not a git repo", stdout: "", stderr: "fatal: not a git repository", exit_code: 128) }

    before do
      allow(container_service).to receive(:execute).and_return(success_result)

      allow(container_service).to receive(:execute)
        .with([ "git", "rev-parse", "--is-inside-work-tree" ], timeout: nil, stream: false)
        .and_return(not_a_repo_result)

      allow(container_service).to receive(:execute)
        .with([ "git", "merge-base", "main", "HEAD" ], timeout: nil, stream: false)
        .and_return(Containers::Provision::Result.success(stdout: "#{merge_base_sha}\n", stderr: "", exit_code: 0))
    end

    it "clones and checks out the existing branch" do
      expect(container_service).to receive(:execute)
        .with([ "git", "clone", "https://github.com/#{project.full_name}.git", "." ],
              timeout: 120, stream: false)
        .and_return(success_result)

      expect(container_service).to receive(:execute)
        .with([ "git", "checkout", "fix-bug-branch" ], timeout: nil, stream: false)
        .and_return(success_result)

      git_ops.clone_and_checkout_branch(branch_name: "fix-bug-branch")

      expect(agent_run.reload.branch_name).to eq("fix-bug-branch")
      expect(agent_run.worktree_path).to eq("/workspace")
      expect(agent_run.base_commit_sha).to eq(merge_base_sha)
    end

    it "raises CloneError when checkout fails" do
      allow(container_service).to receive(:execute)
        .with([ "git", "checkout", "nonexistent" ], timeout: nil, stream: false)
        .and_return(failure_result)

      expect { git_ops.clone_and_checkout_branch(branch_name: "nonexistent") }
        .to raise_error(described_class::CloneError, /Checkout failed/)
    end

    it "falls back to HEAD SHA when merge-base fails" do
      allow(container_service).to receive(:execute)
        .with([ "git", "merge-base", "main", "HEAD" ], timeout: nil, stream: false)
        .and_return(failure_result)

      sha_result = Containers::Provision::Result.success(stdout: "#{head_sha}\n", stderr: "", exit_code: 0)
      allow(container_service).to receive(:execute)
        .with([ "git", "rev-parse", "HEAD" ], timeout: nil, stream: false)
        .and_return(sha_result)

      git_ops.clone_and_checkout_branch(branch_name: "fix-bug-branch")

      expect(agent_run.reload.base_commit_sha).to eq(head_sha)
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

    it "uses --force-with-lease for existing PR branches" do
      agent_run.update!(source_pull_request_number: 42)

      expect(container_service).to receive(:execute)
        .with([ "git", "push", "origin", "paid/test-branch", "--force-with-lease" ], timeout: 60, stream: false)
        .and_return(success_result)

      git_ops.push_branch
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

  describe "#head_sha" do
    it "returns the current HEAD SHA" do
      sha_result = Containers::Provision::Result.success(stdout: "abc123def456\n", stderr: "", exit_code: 0)
      allow(container_service).to receive(:execute)
        .with([ "git", "rev-parse", "HEAD" ], timeout: nil, stream: false)
        .and_return(sha_result)

      expect(git_ops.head_sha).to eq("abc123def456")
    end

    it "raises Error when command fails" do
      allow(container_service).to receive(:execute)
        .with([ "git", "rev-parse", "HEAD" ], timeout: nil, stream: false)
        .and_return(failure_result)

      expect { git_ops.head_sha }.to raise_error(described_class::Error, /Failed to get HEAD SHA/)
    end
  end

  describe "#commit_uncommitted_changes" do
    let(:empty_result) { Containers::Provision::Result.success(stdout: "", stderr: "", exit_code: 0) }

    it "returns false when working tree is clean" do
      allow(container_service).to receive(:execute)
        .with([ "git", "status", "--porcelain" ], timeout: nil, stream: false)
        .and_return(empty_result)

      expect(git_ops.commit_uncommitted_changes).to be false
    end

    it "stages and commits when there are uncommitted changes" do
      status_result = Containers::Provision::Result.success(stdout: "M  file.rb\n", stderr: "", exit_code: 0)
      allow(container_service).to receive(:execute)
        .with([ "git", "status", "--porcelain" ], timeout: nil, stream: false)
        .and_return(status_result)

      expect(container_service).to receive(:execute)
        .with([ "git", "add", "-A" ], timeout: nil, stream: false)
        .and_return(success_result)

      expect(container_service).to receive(:execute)
        .with([ "git", "commit", "--no-verify", "-m", "Apply agent changes" ], timeout: nil, stream: false)
        .and_return(success_result)

      expect(git_ops.commit_uncommitted_changes).to be true
    end

    it "raises Error when staging fails" do
      status_result = Containers::Provision::Result.success(stdout: "M  file.rb\n", stderr: "", exit_code: 0)
      allow(container_service).to receive(:execute)
        .with([ "git", "status", "--porcelain" ], timeout: nil, stream: false)
        .and_return(status_result)

      allow(container_service).to receive(:execute)
        .with([ "git", "add", "-A" ], timeout: nil, stream: false)
        .and_return(failure_result)

      expect { git_ops.commit_uncommitted_changes }.to raise_error(described_class::Error, /Failed to stage/)
    end

    it "raises Error when commit fails" do
      status_result = Containers::Provision::Result.success(stdout: "M  file.rb\n", stderr: "", exit_code: 0)
      allow(container_service).to receive(:execute)
        .with([ "git", "status", "--porcelain" ], timeout: nil, stream: false)
        .and_return(status_result)

      allow(container_service).to receive(:execute)
        .with([ "git", "add", "-A" ], timeout: nil, stream: false)
        .and_return(success_result)

      allow(container_service).to receive(:execute)
        .with([ "git", "commit", "--no-verify", "-m", "Apply agent changes" ], timeout: nil, stream: false)
        .and_return(failure_result)

      expect { git_ops.commit_uncommitted_changes }.to raise_error(described_class::Error, /Failed to commit/)
    end
  end

  describe "#has_changes_since?" do
    let(:pre_sha) { "abc123def456" }
    let(:empty_result) { Containers::Provision::Result.success(stdout: "", stderr: "", exit_code: 0) }

    it "returns true when there are new commits since the given SHA" do
      log_result = Containers::Provision::Result.success(stdout: "def789 Add feature\n", stderr: "", exit_code: 0)
      allow(container_service).to receive(:execute)
        .with([ "git", "log", "--oneline", "#{pre_sha}..HEAD" ], timeout: nil, stream: false)
        .and_return(log_result)

      expect(git_ops.has_changes_since?(pre_sha)).to be true
    end

    it "returns true when there are uncommitted changes but no new commits" do
      allow(container_service).to receive(:execute)
        .with([ "git", "log", "--oneline", "#{pre_sha}..HEAD" ], timeout: nil, stream: false)
        .and_return(empty_result)

      status_result = Containers::Provision::Result.success(stdout: "M  file.rb\n", stderr: "", exit_code: 0)
      allow(container_service).to receive(:execute)
        .with([ "git", "status", "--porcelain" ], timeout: nil, stream: false)
        .and_return(status_result)

      expect(git_ops.has_changes_since?(pre_sha)).to be true
    end

    it "returns false when there are no new commits and no uncommitted changes" do
      allow(container_service).to receive(:execute)
        .with([ "git", "log", "--oneline", "#{pre_sha}..HEAD" ], timeout: nil, stream: false)
        .and_return(empty_result)

      allow(container_service).to receive(:execute)
        .with([ "git", "status", "--porcelain" ], timeout: nil, stream: false)
        .and_return(empty_result)

      expect(git_ops.has_changes_since?(pre_sha)).to be false
    end

    it "returns false on error" do
      allow(container_service).to receive(:execute).and_raise(StandardError, "container gone")

      expect(git_ops.has_changes_since?(pre_sha)).to be false
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

  describe "#install_git_hooks" do
    let(:hook_missing_result) { Containers::Provision::Result.failure(error: "not found", stdout: "", stderr: "", exit_code: 1) }
    let(:hook_exists_result) { Containers::Provision::Result.success(stdout: "", stderr: "", exit_code: 0) }

    it "writes pre-commit and pre-push hooks when none exist" do
      allow(container_service).to receive(:execute)
        .with("test -f .git/hooks/pre-commit", timeout: nil, stream: false)
        .and_return(hook_missing_result)
      allow(container_service).to receive(:execute)
        .with("test -f .git/hooks/pre-push", timeout: nil, stream: false)
        .and_return(hook_missing_result)

      expect(container_service).to receive(:execute)
        .with(a_string_matching(/cat > \.git\/hooks\/pre-commit/), timeout: nil, stream: false)
        .and_return(success_result)
      expect(container_service).to receive(:execute)
        .with("chmod +x .git/hooks/pre-commit", timeout: nil, stream: false)
        .and_return(success_result)

      expect(container_service).to receive(:execute)
        .with(a_string_matching(/cat > \.git\/hooks\/pre-push/), timeout: nil, stream: false)
        .and_return(success_result)
      expect(container_service).to receive(:execute)
        .with("chmod +x .git/hooks/pre-push", timeout: nil, stream: false)
        .and_return(success_result)

      git_ops.install_git_hooks(lint_command: "bundle exec rubocop", test_command: "bundle exec rspec")
    end

    it "does not overwrite existing hooks" do
      allow(container_service).to receive(:execute)
        .with("test -f .git/hooks/pre-commit", timeout: nil, stream: false)
        .and_return(hook_exists_result)
      allow(container_service).to receive(:execute)
        .with("test -f .git/hooks/pre-push", timeout: nil, stream: false)
        .and_return(hook_exists_result)

      expect(container_service).not_to receive(:execute)
        .with(a_string_matching(/cat > \.git\/hooks/), anything)

      git_ops.install_git_hooks(lint_command: "bundle exec rubocop", test_command: "bundle exec rspec")
    end

    it "includes lint command in pre-commit hook but not test command" do
      allow(container_service).to receive(:execute).and_return(hook_missing_result)
      allow(container_service).to receive(:execute)
        .with(a_string_matching(/chmod/), anything)
        .and_return(success_result)

      pre_commit_script = nil
      allow(container_service).to receive(:execute)
        .with(a_string_matching(/cat > \.git\/hooks\/pre-commit/), timeout: nil, stream: false) { |cmd, **|
          pre_commit_script = cmd
          success_result
        }

      allow(container_service).to receive(:execute)
        .with(a_string_matching(/cat > \.git\/hooks\/pre-push/), timeout: nil, stream: false)
        .and_return(success_result)

      git_ops.install_git_hooks(lint_command: "ruff check .", test_command: "pytest")

      expect(pre_commit_script).to include("ruff check .")
      expect(pre_commit_script).not_to include("pytest")
    end

    it "includes both lint and test commands in pre-push hook" do
      allow(container_service).to receive(:execute).and_return(hook_missing_result)
      allow(container_service).to receive(:execute)
        .with(a_string_matching(/chmod/), anything)
        .and_return(success_result)

      allow(container_service).to receive(:execute)
        .with(a_string_matching(/cat > \.git\/hooks\/pre-commit/), timeout: nil, stream: false)
        .and_return(success_result)

      pre_push_script = nil
      allow(container_service).to receive(:execute)
        .with(a_string_matching(/cat > \.git\/hooks\/pre-push/), timeout: nil, stream: false) { |cmd, **|
          pre_push_script = cmd
          success_result
        }

      git_ops.install_git_hooks(lint_command: "ruff check .", test_command: "pytest")

      expect(pre_push_script).to include("ruff check .")
      expect(pre_push_script).to include("pytest")
    end

    it "does not raise when hook installation fails with exception" do
      allow(container_service).to receive(:execute).and_raise(StandardError, "container error")

      expect { git_ops.install_git_hooks(lint_command: "rubocop", test_command: "rspec") }.not_to raise_error
    end

    it "does not raise when hook write returns a failure result" do
      allow(container_service).to receive(:execute)
        .with(a_string_matching(/test -f/), anything)
        .and_return(hook_missing_result)
      allow(container_service).to receive(:execute)
        .with(a_string_matching(/cat > \.git\/hooks/), anything)
        .and_return(failure_result)

      expect { git_ops.install_git_hooks(lint_command: "rubocop", test_command: "rspec") }.not_to raise_error
    end

    describe "command validation" do
      it "accepts simple commands" do
        allow(container_service).to receive(:execute).and_return(hook_missing_result)
        allow(container_service).to receive(:execute)
          .with(a_string_matching(/cat > \.git\/hooks/), anything)
          .and_return(success_result)
        allow(container_service).to receive(:execute)
          .with(a_string_matching(/chmod/), anything)
          .and_return(success_result)

        expect { git_ops.install_git_hooks(lint_command: "bundle exec rubocop", test_command: "bundle exec rspec") }
          .not_to raise_error
      end

      it "accepts commands with paths and dots" do
        allow(container_service).to receive(:execute).and_return(hook_missing_result)
        allow(container_service).to receive(:execute)
          .with(a_string_matching(/cat > \.git\/hooks/), anything)
          .and_return(success_result)
        allow(container_service).to receive(:execute)
          .with(a_string_matching(/chmod/), anything)
          .and_return(success_result)

        expect { git_ops.install_git_hooks(lint_command: "ruff check .", test_command: "go test ./...") }
          .not_to raise_error
      end

      it "rejects commands with semicolons" do
        expect { git_ops.install_git_hooks(lint_command: "echo; rm -rf /", test_command: "rspec") }
          .not_to raise_error # rescued by install_git_hooks
      end

      it "rejects commands with backticks" do
        expect { git_ops.install_git_hooks(lint_command: "`malicious`", test_command: "rspec") }
          .not_to raise_error # rescued by install_git_hooks
      end

      it "rejects commands with dollar signs" do
        expect { git_ops.install_git_hooks(lint_command: "echo $HOME", test_command: "rspec") }
          .not_to raise_error # rescued by install_git_hooks
      end

      it "rejects commands with pipes" do
        expect { git_ops.install_git_hooks(lint_command: "cat | sh", test_command: "rspec") }
          .not_to raise_error # rescued by install_git_hooks
      end

      it "rejects commands with shell operators" do
        expect { git_ops.install_git_hooks(lint_command: "true || malicious", test_command: "rspec") }
          .not_to raise_error # rescued by install_git_hooks
      end

      it "logs a warning when command validation fails" do
        allow(Rails.logger).to receive(:warn)

        git_ops.install_git_hooks(lint_command: "echo; rm -rf /", test_command: "rspec")

        expect(Rails.logger).to have_received(:warn).with(
          hash_including(message: "container_git.install_hooks_failed")
        )
      end
    end
  end
end
