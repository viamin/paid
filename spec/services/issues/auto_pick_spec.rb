# frozen_string_literal: true

require "rails_helper"

RSpec.describe Issues::AutoPick do
  let(:project) { create(:project, auto_pick_enabled: true) }

  describe "#call" do
    it "selects the next unblocked open issue and creates a queued agent run" do
      issue = create(:issue, project: project, github_state: "open")

      result = described_class.new(project).call

      expect(result).to be_a(AgentRun)
      expect(result.issue).to eq(issue)
      expect(result.project).to eq(project)
      expect(result.status).to eq("queued")
      expect(result.trigger_type).to eq("automatic")
      expect(result.agent_type).to eq("claude_code")
    end

    it "returns nil when auto_pick is disabled on the project" do
      project.update!(auto_pick_enabled: false)
      create(:issue, project: project, github_state: "open")

      result = described_class.new(project).call

      expect(result).to be_nil
    end

    it "skips issues labeled planning" do
      create(:issue, project: project, labels: [ "planning" ])
      eligible = create(:issue, project: project, labels: [])

      result = described_class.new(project).call

      expect(result.issue).to eq(eligible)
    end

    it "skips issues labeled research" do
      create(:issue, project: project, labels: [ "research" ])

      result = described_class.new(project).call

      expect(result).to be_nil
    end

    it "skips issues labeled waiting" do
      create(:issue, project: project, labels: [ "waiting" ])

      result = described_class.new(project).call

      expect(result).to be_nil
    end

    it "skips issues with mixed labels including excluded ones" do
      create(:issue, project: project, labels: [ "bug", "planning", "urgent" ])
      eligible = create(:issue, project: project, labels: [ "bug", "urgent" ])

      result = described_class.new(project).call

      expect(result.issue).to eq(eligible)
    end

    it "skips issues with open dependencies (blocked issues)" do
      # Give blocked a lower github_number so it would be chosen first if
      # dependency filtering were broken.
      blocked = create(:issue, project: project, github_state: "open", github_number: 1)
      blocking = create(:issue, project: project, github_state: "open", github_number: 2)
      create(:issue_dependency, issue: blocked, depends_on_issue: blocking)

      result = described_class.new(project).call

      expect(result.issue).to eq(blocking)
      expect(result.issue).not_to eq(blocked)
    end

    it "includes issues whose dependencies are all closed" do
      closed_dep = create(:issue, project: project, github_state: "closed")
      unblocked = create(:issue, project: project, github_state: "open")
      create(:issue_dependency, issue: unblocked, depends_on_issue: closed_dep)

      result = described_class.new(project).call

      expect(result.issue).to eq(unblocked)
    end

    it "skips issues with in_progress paid_state" do
      create(:issue, :in_progress, project: project)

      result = described_class.new(project).call

      expect(result).to be_nil
    end

    it "skips issues with completed paid_state" do
      create(:issue, :completed, project: project)

      result = described_class.new(project).call

      expect(result).to be_nil
    end

    it "includes issues with failed paid_state" do
      issue = create(:issue, :failed, project: project)

      result = described_class.new(project).call

      expect(result.issue).to eq(issue)
    end

    it "skips closed issues" do
      create(:issue, project: project, github_state: "closed")

      result = described_class.new(project).call

      expect(result).to be_nil
    end

    it "skips pull requests" do
      create(:issue, :pull_request, project: project)

      result = described_class.new(project).call

      expect(result).to be_nil
    end

    it "returns nil when an issue already has an active agent run (per-project concurrency)" do
      issue_with_run = create(:issue, project: project)
      create(:agent_run, :queued, project: project, issue: issue_with_run)
      create(:issue, project: project)

      result = described_class.new(project).call

      expect(result).to be_nil
    end

    it "picks the issue with the lowest github_number first" do
      later = create(:issue, project: project, github_number: 200)
      earlier = create(:issue, project: project, github_number: 100)

      result = described_class.new(project).call

      expect(result.issue).to eq(earlier)
      expect(later.reload.agent_runs).to be_empty
    end

    it "returns nil when no eligible issues exist" do
      result = described_class.new(project).call

      expect(result).to be_nil
    end

    it "returns nil gracefully when all issues are blocked" do
      a = create(:issue, project: project, github_state: "open")
      b = create(:issue, project: project, github_state: "open")
      create(:issue_dependency, issue: a, depends_on_issue: b)
      create(:issue_dependency, issue: b, depends_on_issue: a)

      result = described_class.new(project).call

      expect(result).to be_nil
    end

    it "returns existing run when RecordNotUnique is raised and active run exists" do
      issue = create(:issue, project: project)

      service = described_class.new(project)
      # Simulate a race: another process creates a run between our SELECT
      # (find_next_eligible_issue) and INSERT (create_agent_run). Stub
      # create! to insert the competing run first, then raise.
      existing_run = nil
      original_create = AgentRun.method(:create!)
      allow(AgentRun).to receive(:create!) do |**attrs|
        existing_run = original_create.call(**attrs)
        raise ActiveRecord::RecordNotUnique, "idx_agent_runs_unique_active_issue"
      end
      allow(Rails.logger).to receive(:info)

      result = service.call

      expect(result).to eq(existing_run)
      expect(Rails.logger).to have_received(:info).with(
        hash_including(message: "auto_pick.duplicate_existing_run", agent_run_id: existing_run.id)
      )
    end

    it "returns nil when RecordNotUnique is raised but no active run exists" do
      create(:issue, project: project)

      service = described_class.new(project)
      allow(AgentRun).to receive(:create!).and_raise(
        ActiveRecord::RecordNotUnique.new("idx_agent_runs_unique_active_issue")
      )
      allow(Rails.logger).to receive(:info)

      result = service.call

      expect(result).to be_nil
      expect(Rails.logger).to have_received(:info).with(
        hash_including(message: "auto_pick.duplicate_skipped")
      )
    end

    it "re-raises RecordNotUnique for unrelated constraints" do
      create(:issue, project: project)

      service = described_class.new(project)
      allow(AgentRun).to receive(:create!).and_raise(
        ActiveRecord::RecordNotUnique.new("some_other_index")
      )

      expect { service.call }.to raise_error(ActiveRecord::RecordNotUnique)
    end

    it "skips issues created by untrusted GitHub users" do
      create(:issue, project: project, github_creator_login: "untrusted-user")
      trusted_issue = create(:issue, project: project, github_creator_login: "viamin")

      result = described_class.new(project).call

      expect(result.issue).to eq(trusted_issue)
    end

    it "returns nil when only untrusted issues exist" do
      create(:issue, project: project, github_creator_login: "untrusted-user")

      result = described_class.new(project).call

      expect(result).to be_nil
    end

    it "logs the auto-pick event" do
      issue = create(:issue, project: project)

      allow(Rails.logger).to receive(:info)

      described_class.new(project).call

      expect(Rails.logger).to have_received(:info).with(
        hash_including(message: "auto_pick.issue_selected", issue_id: issue.id)
      )
    end

    context "with per-project concurrency limit" do
      it "returns nil when project has a queued agent run" do
        create(:agent_run, :queued, project: project)
        create(:issue, project: project)

        result = described_class.new(project).call

        expect(result).to be_nil
      end

      it "returns nil when project has a running agent run" do
        create(:agent_run, :running, project: project)
        create(:issue, project: project)

        result = described_class.new(project).call

        expect(result).to be_nil
      end

      it "returns nil when project has a pending agent run" do
        create(:agent_run, project: project, status: "pending")
        create(:issue, project: project)

        result = described_class.new(project).call

        expect(result).to be_nil
      end

      it "picks an issue when all project runs are finished" do
        closed_issue = create(:issue, :closed, project: project)
        create(:agent_run, :completed, project: project, issue: closed_issue)
        create(:agent_run, :failed, project: project, issue: closed_issue)
        issue = create(:issue, project: project)

        result = described_class.new(project).call

        expect(result).to be_a(AgentRun)
        expect(result.issue).to eq(issue)
      end

      it "does not count runs from other projects" do
        other_project = create(:project, auto_pick_enabled: true)
        create(:agent_run, :running, project: other_project)
        issue = create(:issue, project: project)

        result = described_class.new(project).call

        expect(result).to be_a(AgentRun)
        expect(result.issue).to eq(issue)
      end
    end

    context "when project has PRs needing attention" do
      it "returns nil when project has an open PR in in_progress state" do
        create(:issue, :pull_request, :in_progress, project: project)
        create(:issue, project: project)

        result = described_class.new(project).call

        expect(result).to be_nil
      end

      it "returns nil when project has an open PR in failed state" do
        create(:issue, :pull_request, :failed, project: project)
        create(:issue, project: project)

        result = described_class.new(project).call

        expect(result).to be_nil
      end

      it "picks an issue when a paid-generated PR is paid-ready and out of draft" do
        create(:issue, :pull_request, :in_progress,
          project: project,
          labels: [ "paid-generated", "paid-ready" ],
          pr_review_phase: "ready")
        issue = create(:issue, project: project)

        result = described_class.new(project).call

        expect(result).to be_a(AgentRun)
        expect(result.issue).to eq(issue)
      end

      it "returns nil when a paid-generated PR is paid-ready but still in draft" do
        create(:issue, :pull_request, :in_progress,
          project: project,
          labels: [ "paid-generated", "paid-ready" ],
          pr_review_phase: "draft")
        create(:issue, project: project)

        result = described_class.new(project).call

        expect(result).to be_nil
      end

      it "returns nil when a paid-generated PR leaves draft without the paid-ready label" do
        create(:issue, :pull_request, :in_progress,
          project: project,
          labels: [ "paid-generated" ],
          pr_review_phase: "ready")
        create(:issue, project: project)

        result = described_class.new(project).call

        expect(result).to be_nil
      end

      it "returns nil when a paid-ready PR is in restarted review phase" do
        create(:issue, :pull_request, :in_progress,
          project: project,
          labels: [ "paid-generated", "paid-ready" ],
          pr_review_phase: "restarted")
        create(:issue, project: project)

        result = described_class.new(project).call

        expect(result).to be_nil
      end

      it "returns nil when a paid-ready PR has failed" do
        create(:issue, :pull_request, :failed,
          project: project,
          labels: [ "paid-generated", "paid-ready" ],
          pr_review_phase: "ready")
        create(:issue, project: project)

        result = described_class.new(project).call

        expect(result).to be_nil
      end

      it "returns nil when open PRs already have active agent runs (per-project concurrency limit)" do
        pr = create(:issue, :pull_request, :in_progress, project: project)
        create(:agent_run, :running, project: project, issue: pr)
        create(:issue, project: project)

        # Project has an active run, so it should return nil due to
        # per-project concurrency limit (not PR check)
        result = described_class.new(project).call

        expect(result).to be_nil
      end

      it "picks an issue when all PRs are completed" do
        create(:issue, :pull_request, :completed, project: project)
        issue = create(:issue, project: project)

        result = described_class.new(project).call

        expect(result).to be_a(AgentRun)
        expect(result.issue).to eq(issue)
      end

      it "picks an issue when all PRs are closed" do
        create(:issue, :pull_request, project: project, github_state: "closed")
        issue = create(:issue, project: project)

        result = described_class.new(project).call

        expect(result).to be_a(AgentRun)
        expect(result.issue).to eq(issue)
      end

      it "picks an issue when PRs are in new state" do
        create(:issue, :pull_request, project: project, paid_state: "new")
        issue = create(:issue, project: project)

        result = described_class.new(project).call

        expect(result).to be_a(AgentRun)
        expect(result.issue).to eq(issue)
      end
    end
  end
end
