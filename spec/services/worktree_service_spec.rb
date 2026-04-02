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
    allow(described_class).to receive(:workspace_root).and_return(workspace_root)
  end

  after do
    FileUtils.rm_rf(workspace_root)
  end

  describe ".workspace_root" do
    it "returns a string path" do
      expect(described_class.workspace_root).to be_a(String)
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

      context "with max_fetch_age and a recent FETCH_HEAD" do
        before do
          FileUtils.touch(File.join(repo_path, "FETCH_HEAD"))
        end

        it "skips fetching when fetched within max_fetch_age" do
          expect(service).not_to receive(:fetch_latest)

          service.ensure_cloned(max_fetch_age: 2.minutes)
        end

        it "fetches when FETCH_HEAD is older than max_fetch_age" do
          fetch_head = File.join(repo_path, "FETCH_HEAD")
          FileUtils.touch(fetch_head, mtime: 5.minutes.ago.to_time)

          expect(service).to receive(:fetch_latest)

          service.ensure_cloned(max_fetch_age: 2.minutes)
        end
      end
    end

    it "returns the repo path" do
      allow(service).to receive(:clone_repository)

      result = service.ensure_cloned
      expect(result).to eq(repo_path)
    end
  end

  describe "fetch refspec for bare clones" do
    describe "#clone_repository (private)" do
      it "configures fetch refspec after bare clone" do
        allow(service).to receive(:run_git)

        # clone_repository now delegates to ensure_fetch_refspec, which uses --get-all/--add
        allow(service).to receive(:run_git)
          .with("config", "--get-all", "remote.origin.fetch", chdir: repo_path, raise_on_error: false)
          .and_return("")

        expect(service).to receive(:run_git).with(
          "config", "--add", "remote.origin.fetch", described_class::FETCH_REFSPEC,
          chdir: repo_path
        )

        service.ensure_cloned
      end
    end

    describe "#ensure_fetch_refspec via fetch_latest" do
      before do
        FileUtils.mkdir_p(repo_path)
        FileUtils.touch(File.join(repo_path, "HEAD"))
        allow(service).to receive(:run_git)
      end

      it "adds refspec when bare repo lacks remote.origin.fetch" do
        allow(service).to receive(:run_git)
          .with("config", "--get-all", "remote.origin.fetch", chdir: repo_path, raise_on_error: false)
          .and_return("")

        expect(service).to receive(:run_git).with(
          "config", "--add", "remote.origin.fetch", described_class::FETCH_REFSPEC,
          chdir: repo_path
        )

        service.ensure_cloned
      end

      it "adds refspec when repo has a different refspec but not the desired one" do
        allow(service).to receive(:run_git)
          .with("config", "--get-all", "remote.origin.fetch", chdir: repo_path, raise_on_error: false)
          .and_return("+refs/tags/*:refs/tags/*\n")

        expect(service).to receive(:run_git).with(
          "config", "--add", "remote.origin.fetch", described_class::FETCH_REFSPEC,
          chdir: repo_path
        )

        service.ensure_cloned
      end

      it "skips adding refspec when already configured" do
        allow(service).to receive(:run_git)
          .with("config", "--get-all", "remote.origin.fetch", chdir: repo_path, raise_on_error: false)
          .and_return("#{described_class::FETCH_REFSPEC}\n")

        expect(service).not_to receive(:run_git).with(
          "config", "--add", "remote.origin.fetch", described_class::FETCH_REFSPEC,
          chdir: repo_path
        )

        service.ensure_cloned
      end

      it "skips adding refspec when desired refspec exists among multiple" do
        allow(service).to receive(:run_git)
          .with("config", "--get-all", "remote.origin.fetch", chdir: repo_path, raise_on_error: false)
          .and_return("+refs/tags/*:refs/tags/*\n#{described_class::FETCH_REFSPEC}\n")

        expect(service).not_to receive(:run_git).with(
          "config", "--add", "remote.origin.fetch", described_class::FETCH_REFSPEC,
          chdir: repo_path
        )

        service.ensure_cloned
      end

      it "caches the refspec check so subsequent fetches skip git config" do
        allow(service).to receive(:run_git)
          .with("config", "--get-all", "remote.origin.fetch", chdir: repo_path, raise_on_error: false)
          .and_return("#{described_class::FETCH_REFSPEC}\n")

        service.ensure_cloned
        service.ensure_cloned

        expect(service).to have_received(:run_git)
          .with("config", "--get-all", "remote.origin.fetch", chdir: repo_path, raise_on_error: false)
          .once
      end
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

    it "raises Error on git failure" do
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

    context "when worktree directory is missing" do
      let(:git_success) { instance_double(Process::Status, success?: true) }

      before do
        FileUtils.rm_rf(worktree_dir)
        allow(Open3).to receive(:capture3).and_return([ "", "", git_success ])
      end

      it "still marks the worktree as cleaned" do
        service.remove_worktree(agent_run)

        expect(worktree.reload.status).to eq("cleaned")
      end

      it "skips git worktree remove but still cleans up branch" do
        service.remove_worktree(agent_run)

        expect(Open3).not_to have_received(:capture3).with(
          "git", "worktree", "remove", anything, anything,
          hash_including(:chdir)
        )
        expect(Open3).to have_received(:capture3).with(
          "git", "branch", "-D", "paid/test-branch",
          chdir: repo_path
        )
      end
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

  describe "#run_repo_command" do
    before do
      FileUtils.mkdir_p(repo_path)
    end

    it "delegates to run_git with the project repo path" do
      allow(service).to receive(:run_git)
        .with("rev-list", "--count", "abc..def", chdir: repo_path)
        .and_return("5\n")

      expect(service.run_repo_command("rev-list", "--count", "abc..def")).to eq("5\n")
    end

    it "raises repo directory missing when directory does not exist" do
      FileUtils.rm_rf(repo_path)
      allow(service).to receive(:run_git).and_raise(Errno::ENOENT, "No such file")

      expect { service.run_repo_command("status") }
        .to raise_error(WorktreeService::Error, /Repo directory missing/)
    end

    it "raises spawn error when directory exists but git executable is missing" do
      allow(service).to receive(:run_git).and_raise(Errno::ENOENT, "No such file")

      expect { service.run_repo_command("status") }
        .to raise_error(WorktreeService::Error, /Failed to execute git/)
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

    it "raises WorktreeError when branch_name is blank" do
      agent_run.update!(branch_name: nil)

      expect { service.push_branch(agent_run) }.to raise_error(
        described_class::WorktreeError, /branch_name is blank/
      )
    end

    it "raises WorktreeError when worktree_path is blank" do
      agent_run.update!(worktree_path: nil)

      expect { service.push_branch(agent_run) }.to raise_error(
        described_class::WorktreeError, /worktree_path is blank/
      )
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
