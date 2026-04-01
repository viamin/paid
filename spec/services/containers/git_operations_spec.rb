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

      # The clone is skipped when rev-parse HEAD succeeds (idempotency guard),
      # so return failure first (triggering clone), then success (for head_sha).
      sha_result = Containers::Provision::Result.success(stdout: "#{head_sha}\n", stderr: "", exit_code: 0)
      allow(container_service).to receive(:execute)
        .with([ "git", "rev-parse", "HEAD" ], timeout: nil, stream: false)
        .and_return(not_a_repo_result, sha_result)
    end

    it "clones the repository inside the container" do
      expect(container_service).to receive(:execute)
        .with([ "git", "clone", "--depth", "1", "https://github.com/#{project.full_name}.git", "." ],
              timeout: described_class::DEFAULT_CLONE_TIMEOUT, stream: false)
        .and_return(success_result)

      git_ops.clone_and_setup_branch
    end

    it "cleans a partial clone before retrying" do
      expect(container_service).to receive(:execute)
        .with("find . -mindepth 1 -maxdepth 1 -print -quit", timeout: nil, stream: false)
        .and_return(Containers::Provision::Result.success(stdout: ".git\n", stderr: "", exit_code: 0))
        .ordered

      expect(container_service).to receive(:execute)
        .with("find . -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +", timeout: nil, stream: false)
        .and_return(success_result)
        .ordered

      expect(container_service).to receive(:execute)
        .with([ "git", "clone", "--depth", "1", "https://github.com/#{project.full_name}.git", "." ],
              timeout: described_class::DEFAULT_CLONE_TIMEOUT, stream: false)
        .and_return(success_result)
        .ordered

      git_ops.clone_and_setup_branch
    end

    it "raises CloneError when partial clone cleanup fails" do
      allow(container_service).to receive(:execute)
        .with("find . -mindepth 1 -maxdepth 1 -print -quit", timeout: nil, stream: false)
        .and_return(Containers::Provision::Result.success(stdout: ".git\n", stderr: "", exit_code: 0))

      allow(container_service).to receive(:execute)
        .with("find . -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +", timeout: nil, stream: false)
        .and_return(Containers::Provision::Result.failure(error: "rm failed", stdout: "", stderr: "permission denied", exit_code: 1))

      expect { git_ops.clone_and_setup_branch }
        .to raise_error(described_class::CloneError, /Failed to clean partial clone/)
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
        .with([ "git", "rev-parse", "HEAD" ], timeout: nil, stream: false)
        .and_return(not_a_repo_result)

      allow(container_service).to receive(:execute)
        .with([ "git", "merge-base", "main", "HEAD" ], timeout: nil, stream: false)
        .and_return(Containers::Provision::Result.success(stdout: "#{merge_base_sha}\n", stderr: "", exit_code: 0))
    end

    it "clones and checks out the existing branch via fetch" do
      # First switch attempt fails (branch not local yet in shallow clone)
      allow(container_service).to receive(:execute)
        .with([ "git", "switch", "--", "fix-bug-branch" ], timeout: nil, stream: false)
        .and_return(failure_result, success_result)

      expect(container_service).to receive(:execute)
        .with([ "git", "clone", "--depth", "1", "https://github.com/#{project.full_name}.git", "." ],
              timeout: described_class::DEFAULT_CLONE_TIMEOUT, stream: false)
        .and_return(success_result)

      expect(container_service).to receive(:execute)
        .with([ "git", "fetch", "--depth", "1", "origin", "refs/heads/fix-bug-branch:refs/remotes/origin/fix-bug-branch" ], timeout: nil, stream: false)
        .and_return(success_result)

      expect(container_service).to receive(:execute)
        .with([ "git", "checkout", "-B", "fix-bug-branch", "refs/remotes/origin/fix-bug-branch" ], timeout: nil, stream: false)
        .and_return(success_result)

      git_ops.clone_and_checkout_branch(branch_name: "fix-bug-branch")

      expect(agent_run.reload.branch_name).to eq("fix-bug-branch")
      expect(agent_run.worktree_path).to eq("/workspace")
      expect(agent_run.base_commit_sha).to eq(merge_base_sha)
    end

    it "skips clone and fetch when branch already exists locally (idempotent retry)" do
      # On Temporal retry, rev-parse HEAD succeeds (clone already done)
      # and switch succeeds (branch already checked out).
      sha_result = Containers::Provision::Result.success(stdout: "#{head_sha}\n", stderr: "", exit_code: 0)
      allow(container_service).to receive(:execute)
        .with([ "git", "rev-parse", "HEAD" ], timeout: nil, stream: false)
        .and_return(sha_result)

      allow(container_service).to receive(:execute)
        .with([ "git", "switch", "--", "fix-bug-branch" ], timeout: nil, stream: false)
        .and_return(success_result)

      expect(container_service).not_to receive(:execute)
        .with([ "git", "clone", "--depth", "1", "https://github.com/#{project.full_name}.git", "." ],
              timeout: described_class::DEFAULT_CLONE_TIMEOUT, stream: false)

      expect(container_service).not_to receive(:execute)
        .with([ "git", "fetch", "--depth", "1", "origin", "refs/heads/fix-bug-branch:refs/remotes/origin/fix-bug-branch" ], timeout: nil, stream: false)

      git_ops.clone_and_checkout_branch(branch_name: "fix-bug-branch")

      expect(agent_run.reload.branch_name).to eq("fix-bug-branch")
    end

    it "raises CloneError when checkout fails and no PR number given" do
      allow(container_service).to receive(:execute)
        .with([ "git", "switch", "--", "nonexistent" ], timeout: nil, stream: false)
        .and_return(failure_result)

      allow(container_service).to receive(:execute)
        .with([ "git", "fetch", "--depth", "1", "origin", "refs/heads/nonexistent:refs/remotes/origin/nonexistent" ], timeout: nil, stream: false)
        .and_return(failure_result)

      expect { git_ops.clone_and_checkout_branch(branch_name: "nonexistent") }
        .to raise_error(described_class::CloneError, /Checkout failed.*switch:.*fetch:/)
    end

    context "when branch is deleted but PR number is given" do
      it "falls back to fetching the PR ref" do
        # First switch fails (not local), shallow fetch fails (branch deleted),
        # PR ref fetch succeeds, final switch succeeds.
        switch_returns = [ failure_result, success_result ]
        allow(container_service).to receive(:execute)
          .with([ "git", "switch", "--", "deleted-branch" ], timeout: nil, stream: false) { switch_returns.shift }

        allow(container_service).to receive(:execute)
          .with([ "git", "fetch", "--depth", "1", "origin", "refs/heads/deleted-branch:refs/remotes/origin/deleted-branch" ], timeout: nil, stream: false)
          .and_return(failure_result)

        expect(container_service).to receive(:execute)
          .with([ "git", "fetch", "origin", "refs/pull/42/head:deleted-branch" ], timeout: nil, stream: false)
          .and_return(success_result)

        git_ops.clone_and_checkout_branch(branch_name: "deleted-branch", pull_request_number: 42)

        expect(agent_run.reload.branch_name).to eq("deleted-branch")
      end

      it "raises CloneError when PR ref fetch also fails" do
        allow(container_service).to receive(:execute)
          .with([ "git", "switch", "--", "deleted-branch" ], timeout: nil, stream: false)
          .and_return(failure_result)

        allow(container_service).to receive(:execute)
          .with([ "git", "fetch", "--depth", "1", "origin", "refs/heads/deleted-branch:refs/remotes/origin/deleted-branch" ], timeout: nil, stream: false)
          .and_return(failure_result)

        allow(container_service).to receive(:execute)
          .with([ "git", "fetch", "origin", "refs/pull/42/head:deleted-branch" ], timeout: nil, stream: false)
          .and_return(failure_result)

        expect { git_ops.clone_and_checkout_branch(branch_name: "deleted-branch", pull_request_number: 42) }
          .to raise_error(described_class::CloneError, /Branch checkout failed.*PR ref fetch also failed/)
      end
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
    let(:remote_sha) { "abc9999999999999999999999999999999999999" }
    let(:stale_push_result) do
      Containers::Provision::Result.failure(
        error: "Command exited with code 1",
        stdout: "",
        stderr: " ! [rejected] paid/test-branch -> paid/test-branch (stale info)",
        exit_code: 1
      )
    end

    before do
      agent_run.update!(branch_name: "paid/test-branch")
      create(:worktree, project: project, agent_run: agent_run, branch_name: "paid/test-branch", status: "active")

      allow(container_service).to receive(:execute)
        .with([ "git", "push", "--no-verify", "origin", "paid/test-branch" ], timeout: 60, stream: false)
        .and_return(success_result)

      sha_result = Containers::Provision::Result.success(stdout: "#{head_sha}\n", stderr: "", exit_code: 0)
      allow(container_service).to receive(:execute)
        .with([ "git", "rev-parse", "HEAD" ], timeout: nil, stream: false)
        .and_return(sha_result)
    end

    it "pushes the branch with --no-verify and returns the commit SHA" do
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

      allow(container_service).to receive(:execute)
        .with([ "git", "fetch", "origin", "refs/heads/paid/test-branch:refs/remotes/origin/paid/test-branch" ], timeout: nil, stream: false)
        .and_return(success_result)

      allow(container_service).to receive(:execute)
        .with([ "git", "rev-parse", "refs/remotes/origin/paid/test-branch" ], timeout: nil, stream: false)
        .and_return(Containers::Provision::Result.success(stdout: "#{remote_sha}\n", stderr: "", exit_code: 0))

      expect(container_service).to receive(:execute)
        .with([ "git", "push", "--no-verify", "origin", "paid/test-branch", "--force-with-lease=paid/test-branch:#{remote_sha}" ], timeout: 60, stream: false)
        .and_return(success_result)

      git_ops.push_branch
    end

    it "fetches the remote branch before pushing on existing PR branches" do
      agent_run.update!(source_pull_request_number: 42)

      expect_refresh_remote_branch(remote_sha, ordered: true)
      expect_push_with_lease(remote_sha, success_result, ordered: true)

      git_ops.push_branch
    end

    it "does not fetch before pushing on new branches" do
      expect(container_service).not_to receive(:execute)
        .with([ "git", "fetch", "origin", "refs/heads/paid/test-branch:refs/remotes/origin/paid/test-branch" ], timeout: nil, stream: false)

      git_ops.push_branch
    end

    it "raises PushError when fetch fails on existing PR branch" do
      agent_run.update!(source_pull_request_number: 42)

      allow(container_service).to receive(:execute)
        .with([ "git", "fetch", "origin", "refs/heads/paid/test-branch:refs/remotes/origin/paid/test-branch" ], timeout: nil, stream: false)
        .and_return(failure_result)

      expect { git_ops.push_branch }.to raise_error(described_class::PushError, /Fetch failed/)
    end

    it "raises PushError with remote ref context when remote SHA resolution fails" do
      agent_run.update!(source_pull_request_number: 42)
      rev_parse_failure = Containers::Provision::Result.failure(
        error: "Command exited with code 128",
        stdout: "",
        stderr: "fatal: ambiguous argument 'refs/remotes/origin/paid/test-branch'",
        exit_code: 128
      )

      allow(container_service).to receive(:execute)
        .with([ "git", "fetch", "origin", "refs/heads/paid/test-branch:refs/remotes/origin/paid/test-branch" ], timeout: nil, stream: false)
        .and_return(success_result)

      allow(container_service).to receive(:execute)
        .with([ "git", "rev-parse", "refs/remotes/origin/paid/test-branch" ], timeout: nil, stream: false)
        .and_return(rev_parse_failure)

      expect { git_ops.push_branch }.to raise_error(
        described_class::PushError,
        /refs\/remotes\/origin\/paid\/test-branch/
      )
    end

    it "refreshes the explicit remote-tracking ref before resolving the lease SHA" do
      agent_run.update!(source_pull_request_number: 42)

      expect(container_service).to receive(:execute)
        .with([ "git", "fetch", "origin", "refs/heads/paid/test-branch:refs/remotes/origin/paid/test-branch" ], timeout: nil, stream: false)
        .and_return(success_result)
        .ordered

      expect(container_service).to receive(:execute)
        .with([ "git", "rev-parse", "refs/remotes/origin/paid/test-branch" ], timeout: nil, stream: false)
        .and_return(Containers::Provision::Result.success(stdout: "#{remote_sha}\n", stderr: "", exit_code: 0))
        .ordered

      expect(container_service).to receive(:execute)
        .with([ "git", "push", "--no-verify", "origin", "paid/test-branch", "--force-with-lease=paid/test-branch:#{remote_sha}" ], timeout: 60, stream: false)
        .and_return(success_result)
        .ordered

      git_ops.push_branch
    end

    it "rebases onto the refreshed remote branch after a stale info rejection" do
      agent_run.update!(source_pull_request_number: 42)
      refreshed_remote_sha = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"

      expect_refresh_remote_branch(remote_sha, ordered: true)
      expect_push_with_lease(remote_sha, stale_push_result, ordered: true)
      expect_not_shallow_repo(ordered: true)
      expect_refresh_remote_branch(refreshed_remote_sha, ordered: true)

      expect(container_service).to receive(:execute)
        .with([ "git", "rebase", "origin/paid/test-branch" ], timeout: nil, stream: false)
        .and_return(success_result)
        .ordered

      expect_push_with_lease(refreshed_remote_sha, success_result, ordered: true)

      git_ops.push_branch
    end

    it "raises PushError when rebasing after stale info fails" do
      agent_run.update!(source_pull_request_number: 42)
      rebase_failure = Containers::Provision::Result.failure(
        error: "Command exited with code 1",
        stdout: "",
        stderr: "CONFLICT (content): Merge conflict in app/models/example.rb",
        exit_code: 1
      )

      expect_stale_info_recovery_rebase_failure(rebase_failure)

      expect { git_ops.push_branch }.to raise_error(
        described_class::PushError,
        /Rebase onto origin\/paid\/test-branch failed after branch advanced remotely/
      )
    end

    it "raises PushError when branch_name is blank" do
      agent_run.update!(branch_name: nil)

      expect { git_ops.push_branch }.to raise_error(described_class::PushError, /branch_name is blank/)
    end

    it "raises PushError with stderr details when push fails" do
      allow(container_service).to receive(:execute)
        .with(array_including("push"), anything)
        .and_return(failure_result)

      expect { git_ops.push_branch }.to raise_error(described_class::PushError, /error/)
    end

    it "raises PushError when stderr is binary encoded" do
      binary_stderr = "fatal: remote rejected push \xFF".b
      binary_failure = Containers::Provision::Result.failure(
        error: "Command exited with code 1",
        stdout: "",
        stderr: binary_stderr,
        exit_code: 1
      )

      allow(container_service).to receive(:execute)
        .with(array_including("push"), anything)
        .and_return(binary_failure)

      expect { git_ops.push_branch }.to raise_error(
        described_class::PushError,
        /Command exited with code 1.*fatal: remote rejected push/
      )
    end

    it "treats a new-branch retry as success when the remote branch already exists at HEAD" do
      branch_exists_result = Containers::Provision::Result.failure(
        error: "Command exited with code 1",
        stdout: "",
        stderr: " ! [remote rejected] paid/test-branch -> paid/test-branch (cannot lock ref 'refs/heads/paid/test-branch': reference already exists)",
        exit_code: 1
      )

      expect(container_service).to receive(:execute)
        .with([ "git", "push", "--no-verify", "origin", "paid/test-branch" ], timeout: 60, stream: false)
        .ordered
        .and_return(branch_exists_result)

      expect_refresh_remote_branch(head_sha, ordered: true)

      expect(git_ops.push_branch).to eq(head_sha)
      expect(agent_run.reload.result_commit_sha).to eq(head_sha)
      expect(agent_run.worktree.reload).to be_pushed
    end

    it "raises PushError when a new-branch retry finds a different remote SHA" do
      branch_exists_result = Containers::Provision::Result.failure(
        error: "Command exited with code 1",
        stdout: "",
        stderr: " ! [remote rejected] paid/test-branch -> paid/test-branch (cannot lock ref 'refs/heads/paid/test-branch': reference already exists)",
        exit_code: 1
      )

      expect(container_service).to receive(:execute)
        .with([ "git", "push", "--no-verify", "origin", "paid/test-branch" ], timeout: 60, stream: false)
        .ordered
        .and_return(branch_exists_result)

      expect_refresh_remote_branch(remote_sha, ordered: true)

      expect { git_ops.push_branch }.to raise_error(
        described_class::PushError,
        /remote branch paid\/test-branch already exists/
      )
    end

    def expect_refresh_remote_branch(sha, ordered: false)
      receive_fetch = expect(container_service).to receive(:execute)
        .with([ "git", "fetch", "origin", "refs/heads/paid/test-branch:refs/remotes/origin/paid/test-branch" ], timeout: nil, stream: false)
        .and_return(success_result)
      receive_fetch = receive_fetch.ordered if ordered

      receive_rev_parse = expect(container_service).to receive(:execute)
        .with([ "git", "rev-parse", "refs/remotes/origin/paid/test-branch" ], timeout: nil, stream: false)
        .and_return(Containers::Provision::Result.success(stdout: "#{sha}\n", stderr: "", exit_code: 0))
      receive_rev_parse.ordered if ordered
    end

    def expect_push_with_lease(sha, result, ordered: false)
      receive_push = expect(container_service).to receive(:execute)
        .with([ "git", "push", "--no-verify", "origin", "paid/test-branch", "--force-with-lease=paid/test-branch:#{sha}" ], timeout: 60, stream: false)
        .and_return(result)
      receive_push.ordered if ordered
    end

    def expect_not_shallow_repo(ordered: false)
      receive_check = expect(container_service).to receive(:execute)
        .with([ "git", "rev-parse", "--is-shallow-repository" ], timeout: nil, stream: false)
        .and_return(Containers::Provision::Result.success(stdout: "false\n", stderr: "", exit_code: 0))
      receive_check.ordered if ordered
    end

    def expect_stale_info_recovery_rebase_failure(rebase_failure)
      expect_refresh_remote_branch(remote_sha, ordered: true)
      expect_push_with_lease(remote_sha, stale_push_result, ordered: true)
      expect_not_shallow_repo(ordered: true)
      expect_refresh_remote_branch("bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", ordered: true)

      expect(container_service).to receive(:execute)
        .with([ "git", "rebase", "origin/paid/test-branch" ], timeout: nil, stream: false)
        .and_return(rebase_failure)
        .ordered

      expect(container_service).to receive(:execute)
        .with([ "git", "rebase", "--abort" ], timeout: nil, stream: false)
        .and_return(success_result)
        .ordered
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

    it "stages and commits with --no-verify when there are uncommitted changes" do
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

    it "appends the co-author trailer to the commit message when configured" do
      status_result = Containers::Provision::Result.success(stdout: "M  file.rb\n", stderr: "", exit_code: 0)
      allow(container_service).to receive(:execute)
        .with([ "git", "status", "--porcelain" ], timeout: nil, stream: false)
        .and_return(status_result)

      allow(container_service).to receive(:execute)
        .with([ "git", "add", "-A" ], timeout: nil, stream: false)
        .and_return(success_result)

      project.update!(agent_co_author_trailer: "Co-Authored-By: Claude <noreply@anthropic.com>")

      expect(container_service).to receive(:execute)
        .with(
          [ "git", "commit", "--no-verify", "-m",
            "Apply agent changes\n\nCo-Authored-By: Claude <noreply@anthropic.com>" ],
          timeout: nil, stream: false
        )
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

  describe "#fetch_branch" do
    it "fetches the specified branch from origin" do
      expect(container_service).to receive(:execute)
        .with([ "git", "fetch", "origin", "refs/heads/main:refs/remotes/origin/main" ], timeout: nil, stream: false)
        .and_return(success_result)

      git_ops.fetch_branch("main")
    end

    it "raises Error when fetch fails" do
      allow(container_service).to receive(:execute)
        .with([ "git", "fetch", "origin", "refs/heads/main:refs/remotes/origin/main" ], timeout: nil, stream: false)
        .and_return(failure_result)

      expect { git_ops.fetch_branch("main") }.to raise_error(described_class::Error, /Fetch failed/)
    end
  end

  describe "#rebase_onto" do
    let(:fetch_result) { success_result }
    let(:shallow_true_result) { Containers::Provision::Result.success(stdout: "true\n", stderr: "", exit_code: 0) }

    before do
      allow(container_service).to receive(:execute)
        .with([ "git", "rev-parse", "--is-shallow-repository" ], timeout: nil, stream: false)
        .and_return(shallow_true_result)

      allow(container_service).to receive(:execute)
        .with([ "git", "fetch", "--unshallow" ], timeout: described_class::DEFAULT_CLONE_TIMEOUT, stream: false)
        .and_return(success_result)

      allow(container_service).to receive(:execute)
        .with([ "git", "fetch", "origin", "refs/heads/main:refs/remotes/origin/main" ], timeout: nil, stream: false)
        .and_return(fetch_result)
    end

    context "when rebase succeeds" do
      before do
        allow(container_service).to receive(:execute)
          .with([ "git", "rebase", "origin/main" ], timeout: nil, stream: false)
          .and_return(success_result)
      end

      it "returns true" do
        expect(git_ops.rebase_onto("main")).to be true
      end

      it "checks shallow status, unshallows, then fetches before rebasing" do
        expect(container_service).to receive(:execute)
          .with([ "git", "rev-parse", "--is-shallow-repository" ], timeout: nil, stream: false)
          .and_return(shallow_true_result)
          .ordered

        expect(container_service).to receive(:execute)
          .with([ "git", "fetch", "--unshallow" ], timeout: described_class::DEFAULT_CLONE_TIMEOUT, stream: false)
          .and_return(success_result)
          .ordered

        expect(container_service).to receive(:execute)
          .with([ "git", "fetch", "origin", "refs/heads/main:refs/remotes/origin/main" ], timeout: nil, stream: false)
          .and_return(success_result)
          .ordered

        expect(container_service).to receive(:execute)
          .with([ "git", "rebase", "origin/main" ], timeout: nil, stream: false)
          .and_return(success_result)
          .ordered

        git_ops.rebase_onto("main")
      end
    end

    context "when rebase has conflicts" do
      let(:conflict_result) do
        Containers::Provision::Result.failure(
          error: "rebase failed",
          stdout: "CONFLICT (content): Merge conflict in app/model.rb",
          stderr: "Failed to merge in the changes.",
          exit_code: 1
        )
      end

      before do
        allow(container_service).to receive(:execute)
          .with([ "git", "rebase", "origin/main" ], timeout: nil, stream: false)
          .and_return(conflict_result)

        allow(container_service).to receive(:execute)
          .with([ "git", "rebase", "--abort" ], timeout: nil, stream: false)
          .and_return(success_result)
      end

      it "returns false" do
        expect(git_ops.rebase_onto("main")).to be false
      end

      it "aborts the rebase" do
        expect(container_service).to receive(:execute)
          .with([ "git", "rebase", "--abort" ], timeout: nil, stream: false)
          .and_return(success_result)

        git_ops.rebase_onto("main")
      end
    end

    context "when rebase fails for non-conflict reasons" do
      let(:error_result) do
        Containers::Provision::Result.failure(
          error: "rebase failed",
          stdout: "",
          stderr: "fatal: invalid upstream 'origin/main'",
          exit_code: 128
        )
      end

      before do
        allow(container_service).to receive(:execute)
          .with([ "git", "rebase", "origin/main" ], timeout: nil, stream: false)
          .and_return(error_result)

        allow(container_service).to receive(:execute)
          .with([ "git", "rebase", "--abort" ], timeout: nil, stream: false)
          .and_return(success_result)
      end

      it "raises Error" do
        expect { git_ops.rebase_onto("main") }.to raise_error(described_class::Error, /Rebase failed/)
      end

      it "aborts the rebase before raising" do
        expect(container_service).to receive(:execute)
          .with([ "git", "rebase", "--abort" ], timeout: nil, stream: false)
          .and_return(success_result)

        expect { git_ops.rebase_onto("main") }.to raise_error(described_class::Error)
      end
    end

    context "when repo is not shallow" do
      let(:shallow_false_result) { Containers::Provision::Result.success(stdout: "false\n", stderr: "", exit_code: 0) }

      before do
        allow(container_service).to receive(:execute)
          .with([ "git", "rev-parse", "--is-shallow-repository" ], timeout: nil, stream: false)
          .and_return(shallow_false_result)

        allow(container_service).to receive(:execute)
          .with([ "git", "rebase", "origin/main" ], timeout: nil, stream: false)
          .and_return(success_result)
      end

      it "skips unshallow and proceeds with rebase" do
        expect(container_service).not_to receive(:execute)
          .with([ "git", "fetch", "--unshallow" ], timeout: described_class::DEFAULT_CLONE_TIMEOUT, stream: false)

        expect(git_ops.rebase_onto("main")).to be true
      end
    end

    context "when unshallow fails" do
      before do
        allow(container_service).to receive(:execute)
          .with([ "git", "fetch", "--unshallow" ], timeout: described_class::DEFAULT_CLONE_TIMEOUT, stream: false)
          .and_return(failure_result)
      end

      it "raises Error with unshallow details" do
        expect { git_ops.rebase_onto("main") }
          .to raise_error(described_class::Error, /Failed to unshallow/)
      end
    end
  end

  describe "#install_artifact_excludes" do
    it "writes exclude patterns to .git/info/exclude" do
      expect(container_service).to receive(:execute)
        .with(a_string_matching(/\.git\/info\/exclude/), timeout: nil, stream: false)
        .and_return(success_result)

      git_ops.install_artifact_excludes
    end

    it "includes corepack, yarn-cache, and pg-install patterns" do
      script = nil
      allow(container_service).to receive(:execute) { |cmd, **|
        script = cmd
        success_result
      }

      git_ops.install_artifact_excludes

      expect(script).to include(".corepack/")
      expect(script).to include(".yarn-cache/")
      expect(script).to include(".pg-install/")
      expect(script).to include("vendor/bundle/")
    end

    it "guards with grep to prevent duplicate entries on retry" do
      script = nil
      allow(container_service).to receive(:execute) { |cmd, **|
        script = cmd
        success_result
      }

      git_ops.install_artifact_excludes

      expect(script).to include("grep -qF")
      expect(script).to include("# -- Container artifact excludes (added by Paid) --")
    end

    it "logs a warning when the script returns a failure result" do
      allow(container_service).to receive(:execute).and_return(failure_result)
      allow(Rails.logger).to receive(:warn)

      git_ops.install_artifact_excludes

      expect(Rails.logger).to have_received(:warn).with(
        hash_including(message: "container_git.install_excludes_failed")
      )
    end

    it "does not raise on failure result" do
      allow(container_service).to receive(:execute)
        .and_return(failure_result)

      expect { git_ops.install_artifact_excludes }.not_to raise_error
    end

    it "does not raise on unexpected exceptions" do
      allow(container_service).to receive(:execute)
        .and_raise(StandardError, "container gone")

      expect { git_ops.install_artifact_excludes }.not_to raise_error
    end

    it "logs an error on unexpected exceptions" do
      allow(container_service).to receive(:execute)
        .and_raise(StandardError, "container gone")
      allow(Rails.logger).to receive(:error)

      git_ops.install_artifact_excludes

      expect(Rails.logger).to have_received(:error).with(
        hash_including(
          message: "container_git.install_excludes_unexpected_error",
          error_class: "StandardError"
        )
      )
    end
  end

  describe "#install_git_hooks" do
    let(:hook_missing_result) { Containers::Provision::Result.failure(error: "not found", stdout: "", stderr: "", exit_code: 1) }
    let(:hook_exists_result) { Containers::Provision::Result.success(stdout: "", stderr: "", exit_code: 0) }

    it "writes only a pre-commit hook (no pre-push)" do
      allow(container_service).to receive(:execute)
        .with("test -f .git/hooks/pre-commit", timeout: nil, stream: false)
        .and_return(hook_missing_result)

      expect(container_service).to receive(:execute)
        .with(a_string_matching(/cat > \.git\/hooks\/pre-commit/), timeout: nil, stream: false)
        .and_return(success_result)
      expect(container_service).to receive(:execute)
        .with("chmod +x .git/hooks/pre-commit", timeout: nil, stream: false)
        .and_return(success_result)

      expect(container_service).not_to receive(:execute)
        .with(a_string_matching(/pre-push/), anything)

      git_ops.install_git_hooks(lint_command: "bundle exec rubocop", test_command: "bundle exec rspec")
    end

    it "does not overwrite existing pre-commit hook" do
      allow(container_service).to receive(:execute)
        .with("test -f .git/hooks/pre-commit", timeout: nil, stream: false)
        .and_return(hook_exists_result)

      expect(container_service).not_to receive(:execute)
        .with(a_string_matching(/cat > \.git\/hooks/), anything)

      git_ops.install_git_hooks(lint_command: "bundle exec rubocop", test_command: "bundle exec rspec")
    end

    it "includes both lint and test commands in pre-commit hook" do
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

      git_ops.install_git_hooks(lint_command: "ruff check .", test_command: "pytest")

      expect(pre_commit_script).to include("ruff check .")
      expect(pre_commit_script).to include("pytest")
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

  describe "#install_co_author_hook" do
    let(:hook_missing_result) { Containers::Provision::Result.failure(error: "not found", stdout: "", stderr: "", exit_code: 1) }
    let(:hook_exists_result) { Containers::Provision::Result.success(stdout: "", stderr: "", exit_code: 0) }
    let(:marker_missing_result) { Containers::Provision::Result.failure(error: "not found", stdout: "", stderr: "", exit_code: 1) }
    let(:marker_exists_result) { Containers::Provision::Result.success(stdout: "", stderr: "", exit_code: 0) }

    context "when project has a trailer configured" do
      before do
        project.update!(agent_co_author_trailer: "Co-Authored-By: Claude <noreply@anthropic.com>")

        allow(container_service).to receive(:execute)
          .with(a_string_matching(/grep -qF 'Installed by Paid'/), timeout: nil, stream: false)
          .and_return(marker_missing_result)
        allow(container_service).to receive(:execute)
          .with("test -f .git/hooks/commit-msg.original", timeout: nil, stream: false)
          .and_return(hook_missing_result)
        allow(container_service).to receive(:execute)
          .with("test -f .git/hooks/commit-msg", timeout: nil, stream: false)
          .and_return(hook_missing_result)
        allow(container_service).to receive(:execute)
          .with("chmod +x .git/hooks/commit-msg.tmp", timeout: nil, stream: false)
          .and_return(success_result)
        allow(container_service).to receive(:execute)
          .with("mv .git/hooks/commit-msg.tmp .git/hooks/commit-msg", timeout: nil, stream: false)
          .and_return(success_result)
      end

      it "installs a commit-msg hook that appends the trailer" do
        hook_script = nil
        allow(container_service).to receive(:execute)
          .with(a_string_matching(/cat > \.git\/hooks\/commit-msg\.tmp/), timeout: nil, stream: false) { |script, **|
            hook_script = script
            success_result
          }

        git_ops.install_co_author_hook

        expect(hook_script).to include("Co-Authored-By: Claude <noreply@anthropic.com>")
        expect(hook_script).to include("grep -qF --")
      end
    end

    context "when project has no trailer configured" do
      before { project.update!(agent_co_author_trailer: nil) }

      it "does not install a hook" do
        expect(container_service).not_to receive(:execute)

        git_ops.install_co_author_hook
      end
    end

    context "when a commit-msg hook already exists" do
      before do
        project.update!(agent_co_author_trailer: "Co-Authored-By: Claude <noreply@anthropic.com>")

        allow(container_service).to receive(:execute)
          .with(a_string_matching(/grep -qF 'Installed by Paid'/), timeout: nil, stream: false)
          .and_return(marker_missing_result)
        allow(container_service).to receive(:execute)
          .with("test -f .git/hooks/commit-msg.original", timeout: nil, stream: false)
          .and_return(hook_missing_result)
        allow(container_service).to receive(:execute)
          .with("test -f .git/hooks/commit-msg", timeout: nil, stream: false)
          .and_return(hook_exists_result)
        allow(container_service).to receive(:execute)
          .with("mv .git/hooks/commit-msg .git/hooks/commit-msg.original", timeout: nil, stream: false)
          .and_return(success_result)
        allow(container_service).to receive(:execute)
          .with("chmod +x .git/hooks/commit-msg.tmp", timeout: nil, stream: false)
          .and_return(success_result)
        allow(container_service).to receive(:execute)
          .with("mv .git/hooks/commit-msg.tmp .git/hooks/commit-msg", timeout: nil, stream: false)
          .and_return(success_result)
      end

      it "renames the existing hook and installs a wrapper" do
        captured_script = nil
        allow(container_service).to receive(:execute)
          .with(a_string_matching(/cat > \.git\/hooks\/commit-msg\.tmp/), timeout: nil, stream: false) { |script, **|
            captured_script = script
            success_result
          }

        git_ops.install_co_author_hook

        expect(captured_script).to include(".git/hooks/commit-msg.original")
        expect(captured_script).to include("Co-Authored-By: Claude <noreply@anthropic.com>")
        expect(captured_script).to include("#!/bin/sh")
      end
    end

    context "when a prior failed installation left commit-msg.original orphaned" do
      before do
        project.update!(agent_co_author_trailer: "Co-Authored-By: Claude <noreply@anthropic.com>")

        allow(container_service).to receive(:execute)
          .with(a_string_matching(/grep -qF 'Installed by Paid'/), timeout: nil, stream: false)
          .and_return(marker_missing_result)
        # commit-msg.original exists but commit-msg does not
        allow(container_service).to receive(:execute)
          .with("test -f .git/hooks/commit-msg.original", timeout: nil, stream: false)
          .and_return(hook_exists_result)
        allow(container_service).to receive(:execute)
          .with("test -f .git/hooks/commit-msg", timeout: nil, stream: false)
          .and_return(hook_missing_result, hook_exists_result)
        # Restores original hook
        allow(container_service).to receive(:execute)
          .with("mv .git/hooks/commit-msg.original .git/hooks/commit-msg", timeout: nil, stream: false)
          .and_return(success_result)
        # Then proceeds with normal wrapper flow
        allow(container_service).to receive(:execute)
          .with("mv .git/hooks/commit-msg .git/hooks/commit-msg.original", timeout: nil, stream: false)
          .and_return(success_result)
        allow(container_service).to receive(:execute)
          .with("chmod +x .git/hooks/commit-msg.tmp", timeout: nil, stream: false)
          .and_return(success_result)
        allow(container_service).to receive(:execute)
          .with("mv .git/hooks/commit-msg.tmp .git/hooks/commit-msg", timeout: nil, stream: false)
          .and_return(success_result)
      end

      it "restores the original hook before retrying installation" do
        allow(container_service).to receive(:execute)
          .with(a_string_matching(/cat > \.git\/hooks\/commit-msg\.tmp/), timeout: nil, stream: false)
          .and_return(success_result)

        git_ops.install_co_author_hook

        expect(container_service).to have_received(:execute)
          .with("mv .git/hooks/commit-msg.original .git/hooks/commit-msg", timeout: nil, stream: false)
      end
    end

    context "when the hook marker is already present (idempotency)" do
      before { project.update!(agent_co_author_trailer: "Co-Authored-By: Claude <noreply@anthropic.com>") }

      it "skips installation to avoid duplicate appends" do
        allow(container_service).to receive(:execute)
          .with(a_string_matching(/grep -qF 'Installed by Paid'/), timeout: nil, stream: false)
          .and_return(marker_exists_result)

        expect(container_service).not_to receive(:execute)
          .with(a_string_matching(/cat >>/), timeout: nil, stream: false)
        expect(container_service).not_to receive(:execute)
          .with(a_string_matching(/cat > /), timeout: nil, stream: false)

        git_ops.install_co_author_hook
      end
    end

    it "does not raise when installation fails" do
      project.update!(agent_co_author_trailer: "Co-Authored-By: Claude <noreply@anthropic.com>")
      allow(container_service).to receive(:execute).and_raise(StandardError, "container error")

      expect { git_ops.install_co_author_hook }.not_to raise_error
    end
  end
end
