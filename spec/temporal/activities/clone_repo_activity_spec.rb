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
      allow(git_ops).to receive(:install_git_hooks)

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

    it "installs git hooks after cloning" do
      expect(git_ops).to receive(:install_git_hooks).with(
        lint_command: "bundle exec rubocop",
        test_command: "bundle exec rspec"
      )

      activity.execute(agent_run_id: agent_run.id)
    end

    it "raises ActiveRecord::RecordNotFound for invalid agent_run_id" do
      expect { activity.execute(agent_run_id: -1) }.to raise_error(ActiveRecord::RecordNotFound)
    end

    context "when agent_run has an existing PR" do
      let(:github_client) { instance_double(GithubClient) }
      let(:pr_head) { double("pr_head", ref: "existing-feature-branch") } # rubocop:disable RSpec/VerifiedDoubles
      let(:pr_data) { double("pr_data", head: pr_head) } # rubocop:disable RSpec/VerifiedDoubles

      before do
        agent_run.update!(source_pull_request_number: 135)

        allow(GithubClient).to receive(:new).and_return(github_client)
        allow(github_client).to receive(:pull_request)
          .with(project.full_name, 135)
          .and_return(pr_data)
        allow(git_ops).to receive(:clone_and_checkout_branch)
        allow(git_ops).to receive(:install_git_hooks)

        agent_run.update!(
          branch_name: "existing-feature-branch",
          base_commit_sha: "abc123def456",
          worktree_path: "/workspace"
        )
      end

      it "checks out the existing PR branch instead of creating a new one" do
        expect(git_ops).to receive(:clone_and_checkout_branch).with(branch_name: "existing-feature-branch")
        expect(git_ops).not_to receive(:clone_and_setup_branch)

        activity.execute(agent_run_id: agent_run.id)
      end

      it "installs git hooks after checking out existing PR branch" do
        expect(git_ops).to receive(:install_git_hooks).with(
          lint_command: "bundle exec rubocop",
          test_command: "bundle exec rspec"
        )

        activity.execute(agent_run_id: agent_run.id)
      end

      it "reclaims a cleaned worktree record with the same branch name" do
        old_agent_run = create(:agent_run, project: project)
        create(:worktree, :cleaned, project: project, agent_run: old_agent_run,
          branch_name: "existing-feature-branch", created_at: 3.days.ago)

        freeze_time do
          activity.execute(agent_run_id: agent_run.id)

          worktree = Worktree.find_by(project: project, branch_name: "existing-feature-branch")
          expect(worktree.agent_run).to eq(agent_run)
          expect(worktree).to be_active
          expect(worktree.pushed).to be(false)
          expect(worktree.created_at).to eq(Time.current)
          expect(Worktree.stale).not_to include(worktree)
        end
      end

      it "reclaims a cleanup_failed worktree record with the same branch name" do
        old_agent_run = create(:agent_run, project: project)
        create(:worktree, :cleanup_failed, project: project, agent_run: old_agent_run,
          branch_name: "existing-feature-branch", created_at: 3.days.ago)

        freeze_time do
          activity.execute(agent_run_id: agent_run.id)

          worktree = Worktree.find_by(project: project, branch_name: "existing-feature-branch")
          expect(worktree.agent_run).to eq(agent_run)
          expect(worktree).to be_active
          expect(worktree.pushed).to be(false)
          expect(worktree.created_at).to eq(Time.current)
          expect(Worktree.stale).not_to include(worktree)
        end
      end

      it "is idempotent when retried with an active worktree from the same agent_run" do
        create(:worktree, :active, project: project, agent_run: agent_run, branch_name: "existing-feature-branch")

        expect { activity.execute(agent_run_id: agent_run.id) }.not_to change(Worktree, :count)

        worktree = Worktree.find_by(project: project, branch_name: "existing-feature-branch")
        expect(worktree.agent_run).to eq(agent_run)
        expect(worktree).to be_active
      end

      it "raises WorktreeConflict when an active worktree belongs to a different agent_run" do
        other_agent_run = create(:agent_run, :running, project: project)
        create(:worktree, :active, project: project, agent_run: other_agent_run, branch_name: "existing-feature-branch")

        expect { activity.execute(agent_run_id: agent_run.id) }
          .to raise_error(Temporalio::Error::ApplicationError, /active worktree from agent run/)
      end

      it "retries and reclaims when find_by misses a cleaned worktree and create! raises RecordInvalid" do
        old_agent_run = create(:agent_run, project: project)
        cleaned_worktree = create(:worktree, :cleaned, project: project, agent_run: old_agent_run,
          branch_name: "existing-feature-branch", created_at: 3.days.ago)

        # Simulate find_by returning nil on the first call (as observed in
        # production), then finding the record on the retry after RecordInvalid.
        call_count = 0
        allow(Worktree).to receive(:find_by).and_wrap_original do |method, **args|
          call_count += 1
          call_count == 1 ? nil : method.call(**args)
        end

        activity.execute(agent_run_id: agent_run.id)

        cleaned_worktree.reload
        expect(cleaned_worktree.agent_run).to eq(agent_run)
        expect(cleaned_worktree).to be_active
      end
    end
  end
end
