# frozen_string_literal: true

require "rails_helper"

RSpec.describe WorktreeService do
  let(:project) { create(:project) }
  let(:agent_run) { create(:agent_run, project: project) }
  let(:service) { described_class.new(project) }

  let(:workspace_root) { Dir.mktmpdir("workspaces") }
  let(:repo_path) { File.join(workspace_root, project.account_id.to_s, project.id.to_s, "repo") }
  let(:worktrees_path) { File.join(workspace_root, project.account_id.to_s, project.id.to_s, "worktrees") }

  before do
    stub_const("WorktreeService::WORKSPACE_ROOT", workspace_root)
  end

  after do
    FileUtils.rm_rf(workspace_root)
  end

  describe "constants" do
    it "defines WORKSPACE_ROOT with a default" do
      expect(described_class::WORKSPACE_ROOT).to be_a(String)
    end
  end

  describe "#initialize" do
    it "stores the project" do
      expect(service.project).to eq(project)
    end
  end

  describe "#ensure_cloned" do
    context "when repository does not exist" do
      it "clones the repository" do
        expect(service).to receive(:clone_repository)

        service.ensure_cloned
      end
    end

    context "when repository already exists" do
      before do
        FileUtils.mkdir_p(repo_path)
        FileUtils.touch(File.join(repo_path, "HEAD"))
        allow(service).to receive(:run_git)
      end

      it "fetches latest changes" do
        expect(service).to receive(:fetch_latest)

        service.ensure_cloned
      end
    end

    it "returns the repo path" do
      allow(service).to receive(:clone_repository)

      result = service.ensure_cloned
      expect(result).to eq(repo_path)
    end
  end

  describe "#create_worktree" do
    before do
      allow(service).to receive(:ensure_cloned)
      allow(service).to receive(:current_commit_sha).and_return("abc123def456789012345678901234567890abcd")
      allow(service).to receive(:run_git)
      FileUtils.mkdir_p(worktrees_path)
    end

    it "creates a worktree directory with unique name" do
      allow(service).to receive(:run_git)

      result = service.create_worktree(agent_run)

      expect(result).to start_with(worktrees_path)
      expect(result).to include("paid-agent-#{agent_run.id}")
    end

    it "updates agent_run with worktree details" do
      service.create_worktree(agent_run)

      agent_run.reload
      expect(agent_run.worktree_path).to be_present
      expect(agent_run.branch_name).to start_with("paid/paid-agent-")
      expect(agent_run.base_commit_sha).to eq("abc123def456789012345678901234567890abcd")
    end

    it "creates a Worktree database record" do
      expect { service.create_worktree(agent_run) }.to change(Worktree, :count).by(1)

      worktree = Worktree.last
      expect(worktree.project).to eq(project)
      expect(worktree.agent_run).to eq(agent_run)
      expect(worktree.status).to eq("active")
      expect(worktree.base_commit).to eq("abc123def456789012345678901234567890abcd")
    end

    it "runs git worktree add command" do
      expect(service).to receive(:run_git).with(
        "worktree", "add", "-b",
        a_string_matching(/\Apaid\/paid-agent-/),
        a_string_matching(/\A#{Regexp.escape(worktrees_path)}/),
        "origin/#{project.default_branch}",
        chdir: repo_path
      )

      service.create_worktree(agent_run)
    end

    it "logs worktree creation to agent run" do
      expect(agent_run).to receive(:log!).with("system", a_string_matching(/Worktree created:/))

      service.create_worktree(agent_run)
    end

    it "raises WorktreeError on git failure" do
      allow(service).to receive(:run_git)
        .with("worktree", "add", "-b", anything, anything, anything, chdir: anything)
        .and_raise(described_class::Error, "git failed")

      expect { service.create_worktree(agent_run) }.to raise_error(described_class::Error)
    end

    it "generates unique branch names for parallel runs" do
      path1 = service.create_worktree(agent_run)

      other_run = create(:agent_run, project: project)
      path2 = service.create_worktree(other_run)

      expect(path1).not_to eq(path2)
      expect(agent_run.reload.branch_name).not_to eq(other_run.reload.branch_name)
    end
  end

  describe "#remove_worktree" do
    let(:worktree_dir) { File.join(worktrees_path, "paid-agent-test") }
    let(:worktree) do
      create(:worktree,
        project: project,
        agent_run: agent_run,
        path: worktree_dir,
        branch_name: "paid/test-branch")
    end

    before do
      agent_run.update!(
        worktree_path: worktree_dir,
        branch_name: "paid/test-branch"
      )
      FileUtils.mkdir_p(worktree_dir)
      FileUtils.mkdir_p(repo_path)
      worktree # create the worktree record
    end

    it "removes the worktree via git" do
      expect(service).to receive(:run_git).with(
        "worktree", "remove", worktree_dir, "--force",
        chdir: repo_path
      )
      expect(service).to receive(:run_git).with(
        "branch", "-D", "paid/test-branch",
        chdir: repo_path,
        raise_on_error: false
      )

      service.remove_worktree(agent_run)
    end

    it "marks the worktree record as cleaned" do
      allow(service).to receive(:run_git)

      service.remove_worktree(agent_run)

      expect(worktree.reload.status).to eq("cleaned")
      expect(worktree.cleaned_at).to be_present
    end

    it "skips branch deletion for pushed worktrees" do
      worktree.mark_pushed!

      expect(service).to receive(:run_git).with(
        "worktree", "remove", worktree_dir, "--force",
        chdir: repo_path
      )
      expect(service).not_to receive(:run_git).with(
        "branch", "-D", anything,
        chdir: anything, raise_on_error: anything
      )

      service.remove_worktree(agent_run)
    end

    it "logs removal to agent run" do
      allow(service).to receive(:run_git)

      expect(agent_run).to receive(:log!).with("system", "Worktree removed")

      service.remove_worktree(agent_run)
    end

    it "does nothing when worktree is already cleaned" do
      worktree.mark_cleaned!

      expect(service).not_to receive(:run_git)

      service.remove_worktree(agent_run)
    end

    it "marks cleanup_failed on error" do
      allow(service).to receive(:run_git).and_raise(StandardError, "git error")

      service.remove_worktree(agent_run)

      expect(worktree.reload.status).to eq("cleanup_failed")
    end
  end

  describe "#current_commit_sha" do
    before do
      FileUtils.mkdir_p(repo_path)
    end

    it "returns the SHA of the default branch" do
      expected_sha = "abc123def456789012345678901234567890abcd"
      allow(service).to receive(:run_git)
        .with("rev-parse", "origin/#{project.default_branch}", chdir: repo_path)
        .and_return("#{expected_sha}\n")

      expect(service.current_commit_sha).to eq(expected_sha)
    end
  end

  describe "#push_branch" do
    let(:worktree_dir) { File.join(worktrees_path, "paid-agent-test") }
    let(:result_sha) { "def456789012345678901234567890abcdef1234" }

    before do
      agent_run.update!(
        worktree_path: worktree_dir,
        branch_name: "paid/test-branch"
      )
      create(:worktree,
        project: project,
        agent_run: agent_run,
        path: worktree_dir,
        branch_name: "paid/test-branch")
      FileUtils.mkdir_p(worktree_dir)
    end

    it "pushes the branch to remote" do
      expect(service).to receive(:run_git)
        .with("push", "origin", "paid/test-branch", chdir: worktree_dir)
      allow(service).to receive(:run_git)
        .with("rev-parse", "HEAD", chdir: worktree_dir)
        .and_return("#{result_sha}\n")

      service.push_branch(agent_run)
    end

    it "updates agent_run with result commit SHA" do
      allow(service).to receive(:run_git)
        .with("push", "origin", "paid/test-branch", chdir: worktree_dir)
      allow(service).to receive(:run_git)
        .with("rev-parse", "HEAD", chdir: worktree_dir)
        .and_return("#{result_sha}\n")

      service.push_branch(agent_run)

      expect(agent_run.reload.result_commit_sha).to eq(result_sha)
    end

    it "marks the worktree as pushed" do
      allow(service).to receive(:run_git)
        .with("push", "origin", "paid/test-branch", chdir: worktree_dir)
      allow(service).to receive(:run_git)
        .with("rev-parse", "HEAD", chdir: worktree_dir)
        .and_return("#{result_sha}\n")

      service.push_branch(agent_run)

      expect(agent_run.worktree.reload.pushed).to be true
    end

    it "returns the result SHA" do
      allow(service).to receive(:run_git)
        .with("push", "origin", "paid/test-branch", chdir: worktree_dir)
      allow(service).to receive(:run_git)
        .with("rev-parse", "HEAD", chdir: worktree_dir)
        .and_return("#{result_sha}\n")

      expect(service.push_branch(agent_run)).to eq(result_sha)
    end
  end

  describe "#cleanup_stale_worktrees" do
    before do
      FileUtils.mkdir_p(repo_path)
    end

    context "when worktrees_path does not exist" do
      it "returns without error" do
        expect { service.cleanup_stale_worktrees }.not_to raise_error
      end
    end

    context "when stale worktrees exist" do
      let(:stale_dir) { File.join(worktrees_path, "paid-agent-stale") }
      let(:fresh_dir) { File.join(worktrees_path, "paid-agent-fresh") }

      before do
        FileUtils.mkdir_p(stale_dir)
        FileUtils.mkdir_p(fresh_dir)
        FileUtils.touch(stale_dir, mtime: 25.hours.ago.to_time)
      end

      it "removes stale worktrees" do
        expect(service).to receive(:run_git).with(
          "worktree", "remove", stale_dir, "--force",
          chdir: repo_path,
          raise_on_error: false
        )
        expect(service).to receive(:run_git).with(
          "worktree", "prune",
          chdir: repo_path,
          raise_on_error: false
        )

        service.cleanup_stale_worktrees
      end

      it "does not remove fresh worktrees" do
        allow(service).to receive(:run_git)

        expect(service).not_to receive(:run_git).with(
          "worktree", "remove", fresh_dir, "--force",
          chdir: repo_path,
          raise_on_error: false
        )

        service.cleanup_stale_worktrees
      end
    end
  end

  describe "error classes" do
    describe "CloneError" do
      it "is a subclass of Error" do
        expect(described_class::CloneError).to be < described_class::Error
      end
    end

    describe "WorktreeError" do
      it "is a subclass of Error" do
        expect(described_class::WorktreeError).to be < described_class::Error
      end
    end
  end
end
