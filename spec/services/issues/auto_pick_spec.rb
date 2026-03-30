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

    it "picks another eligible issue when the project already has an active run" do
      issue_with_run = create(:issue, project: project)
      create(:agent_run, :queued, project: project, issue: issue_with_run)
      eligible = create(:issue, project: project)

      result = described_class.new(project).call

      expect(result.issue).to eq(eligible)
    end

    it "queues another auto-pick run when a different issue is already queued" do
      first = create(:issue, project: project, github_number: 1)
      second = create(:issue, project: project, github_number: 2)
      create(:agent_run, :queued, project: project, issue: first, trigger_type: "automatic")

      result = described_class.new(project).call

      expect(result.issue).to eq(second)
      expect(project.agent_runs.queued.where(trigger_type: "automatic").count).to eq(2)
    end

    it "picks the issue with the lowest github_number first (no dependencies)" do
      later = create(:issue, project: project, github_number: 200)
      earlier = create(:issue, project: project, github_number: 100)

      result = described_class.new(project).call

      expect(result.issue).to eq(earlier)
      expect(later.reload.agent_runs).to be_empty
    end

    it "skips issues labeled tracking" do
      create(:issue, project: project, labels: [ "tracking" ])

      result = described_class.new(project).call

      expect(result).to be_nil
    end

    it "skips issues labeled epic" do
      create(:issue, project: project, labels: [ "epic" ])

      result = described_class.new(project).call

      expect(result).to be_nil
    end

    context "with tracker/meta issues" do
      it "skips a tracker issue when its body references open issues" do
        tracker = create(:issue, project: project, github_number: 413,
          title: "Phase 2 remaining work tracker",
          body: "## Required\n- #262 Redaction\n- #269 Security\n- #410 Search")
        create(:issue, project: project, github_number: 262, github_state: "open")
        create(:issue, project: project, github_number: 269, github_state: "open")

        result = described_class.new(project).call

        # Tracker is not picked; one of the referenced issues is picked instead
        expect(result.issue).not_to eq(tracker)
      end

      it "picks a tracker issue when all body-referenced issues are closed" do
        tracker = create(:issue, project: project, github_number: 413,
          title: "Phase 2 remaining work tracker",
          body: "## Required\n- #262 Redaction\n- #269 Security")
        create(:issue, :closed, project: project, github_number: 262)
        create(:issue, :closed, project: project, github_number: 269)

        result = described_class.new(project).call

        expect(result.issue).to eq(tracker)
      end

      it "picks a tracker issue when it has no body references" do
        tracker = create(:issue, project: project, github_number: 100,
          title: "Completion criteria tracker",
          body: "Just some text with no issue refs")

        result = described_class.new(project).call

        expect(result.issue).to eq(tracker)
      end

      it "does not treat a non-tracker issue with body references as blocked" do
        normal = create(:issue, project: project, github_number: 1,
          title: "Fix the login bug",
          body: "Related to #200 but not dependent")
        create(:issue, project: project, github_number: 200, github_state: "open")

        result = described_class.new(project).call

        expect(result.issue).to eq(normal)
      end

      it "ignores self-references in tracker body" do
        tracker = create(:issue, project: project, github_number: 413,
          title: "Phase tracker",
          body: "This is #413 tracking work for #100")
        create(:issue, :closed, project: project, github_number: 100)

        result = described_class.new(project).call

        expect(result.issue).to eq(tracker)
      end

      it "detects tracker by body content even without tracker in title" do
        tracker = create(:issue, project: project, github_number: 100,
          title: "Phase 2 umbrella",
          body: "## Completion criteria\n- #10 done\n- #11 done")
        create(:issue, project: project, github_number: 10, github_state: "open")

        result = described_class.new(project).call

        # Issue #10 is eligible (lower number); tracker #100 is blocked
        expect(result.issue).not_to eq(tracker)
      end

      it "regression: tracker with mixed explicit deps and body refs" do
        # Simulates #413 scenario: tracker with child issues, explicit deps,
        # and a security issue (#269) that transitively depends on #262
        tracker = create(:issue, project: project, github_number: 413,
          title: "Phase 2 remaining work tracker",
          body: "## Dependencies\nDepends on #410, #411\n\n## Supporting\n- #262\n- #269")
        dep_410 = create(:issue, :closed, project: project, github_number: 410)
        dep_411 = create(:issue, :closed, project: project, github_number: 411)
        create(:issue, project: project, github_number: 262, github_state: "open")
        sec_269 = create(:issue, project: project, github_number: 269, github_state: "open")

        # Even though explicit deps (410, 411) are closed, open body refs block the tracker
        create(:issue_dependency, issue: tracker, depends_on_issue: dep_410)
        create(:issue_dependency, issue: tracker, depends_on_issue: dep_411)

        result = described_class.new(project).call

        # Tracker is blocked by open body refs #262 and #269;
        # #262 is picked instead (lowest eligible number, #269 is blocked by #262)
        expect(result.issue).not_to eq(tracker)
      end
    end

    it "skips parent issues that have sub-issues" do
      parent = create(:issue, project: project, github_number: 1)
      create(:issue, project: project, github_number: 3, parent_issue: parent)
      standalone = create(:issue, project: project, github_number: 2)

      result = described_class.new(project).call

      # Parent (github_number: 1) is skipped; standalone (#2) picked over sub-issue (#3)
      expect(result.issue).to eq(standalone)
    end

    it "prefers issues that unblock more downstream work" do
      # leaf_a unblocks 2 issues, leaf_b unblocks 1 issue
      leaf_a = create(:issue, project: project, github_number: 10)
      leaf_b = create(:issue, project: project, github_number: 5)
      downstream1 = create(:issue, project: project, github_number: 20)
      downstream2 = create(:issue, project: project, github_number: 21)
      downstream3 = create(:issue, project: project, github_number: 22)

      create(:issue_dependency, issue: downstream1, depends_on_issue: leaf_a)
      create(:issue_dependency, issue: downstream2, depends_on_issue: leaf_a)
      create(:issue_dependency, issue: downstream3, depends_on_issue: leaf_b)

      result = described_class.new(project).call

      # leaf_a unblocks 2, leaf_b unblocks 1 — pick leaf_a despite higher number
      expect(result.issue).to eq(leaf_a)
    end

    it "prefers issues in partially-complete dependency trees" do
      # Tree 1: partially complete (sibling_closed is done)
      tree1_issue = create(:issue, project: project, github_number: 10)
      sibling_closed = create(:issue, :closed, project: project, github_number: 11)
      downstream = create(:issue, project: project, github_number: 20)
      create(:issue_dependency, issue: downstream, depends_on_issue: tree1_issue)
      create(:issue_dependency, issue: downstream, depends_on_issue: sibling_closed)

      # Tree 2: not started (standalone unblocking issue)
      tree2_issue = create(:issue, project: project, github_number: 1)
      tree2_downstream = create(:issue, project: project, github_number: 30)
      create(:issue_dependency, issue: tree2_downstream, depends_on_issue: tree2_issue)

      result = described_class.new(project).call

      # tree1_issue is in a started tree — prefer it over tree2_issue
      expect(result.issue).to eq(tree1_issue)
    end

    it "selects dependency tree issues in correct order" do
      # Build tree: A depends on B and C; B depends on D
      issue_d = create(:issue, project: project, github_number: 4)
      issue_c = create(:issue, project: project, github_number: 3)
      issue_b = create(:issue, project: project, github_number: 2)
      issue_a = create(:issue, project: project, github_number: 1)

      create(:issue_dependency, issue: issue_a, depends_on_issue: issue_b)
      create(:issue_dependency, issue: issue_a, depends_on_issue: issue_c)
      create(:issue_dependency, issue: issue_b, depends_on_issue: issue_d)

      # A and B are blocked; only C and D are eligible.
      # Both have 1 direct unblock (C -> A, D -> B) and neither is in a
      # started tree, so github_number breaks the tie: C (#3) before D (#4).
      result = described_class.new(project).call
      expect(result.issue).to eq(issue_c)
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
      create(:issue, project: project)

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

    it "returns nil and warns when no runnable provider can be resolved" do
      create(:issue, project: project)
      allow(Provider).to receive(:ensure_default_for).and_return(nil)
      allow(AgentRuns::UserSettingsResolver).to receive(:call).and_return(nil)
      allow(Rails.logger).to receive(:warn)

      result = described_class.new(project).call

      expect(result).to be_nil
      expect(Rails.logger).to have_received(:warn).with(
        hash_including(message: "auto_pick.no_runnable_provider", project_id: project.id)
      )
    end

    context "with concurrent auto-pick runs" do
      it "queues another run when project already has a queued agent run" do
        create(:agent_run, :queued, project: project)
        issue = create(:issue, project: project)

        result = described_class.new(project).call

        expect(result.issue).to eq(issue)
      end

      it "queues another run when project already has a running agent run" do
        create(:agent_run, :running, project: project)
        issue = create(:issue, project: project)

        result = described_class.new(project).call

        expect(result.issue).to eq(issue)
      end

      it "queues another run when project already has a pending agent run" do
        create(:agent_run, project: project, status: "pending")
        issue = create(:issue, project: project)

        result = described_class.new(project).call

        expect(result.issue).to eq(issue)
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

      it "returns nil when open PRs already need attention even if a run is already active" do
        pr = create(:issue, :pull_request, :in_progress, project: project)
        create(:agent_run, :running, project: project, issue: pr)
        create(:issue, project: project)

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

    context "with per-issue agent run exclusion" do
      it "skips issues that already have active agent runs but picks others" do
        issue_with_run = create(:issue, project: project)
        create(:agent_run, :queued, project: project, issue: issue_with_run)
        eligible = create(:issue, project: project)

        result = described_class.new(project).call

        expect(result.issue).to eq(eligible)
      end
    end

    context "with synthetic Dependabot issues" do
      it "skips synthetic Dependabot issues (managed by ScanSecurityAlertsActivity)" do
        create(:issue, project: project, source: Issue::SYNTHETIC_DEPENDABOT_SOURCE,
          github_issue_id: Issue::SYNTHETIC_ISSUE_ID_OFFSET + 1,
          github_number: 100_000_001)
        github_issue = create(:issue, project: project, source: Issue::GITHUB_SOURCE)

        result = described_class.new(project).call

        expect(result).to be_a(AgentRun)
        expect(result.issue).to eq(github_issue)
      end

      it "returns nil when only synthetic Dependabot issues exist" do
        create(:issue, project: project, source: Issue::SYNTHETIC_DEPENDABOT_SOURCE,
          github_issue_id: Issue::SYNTHETIC_ISSUE_ID_OFFSET + 1,
          github_number: 100_000_001)

        result = described_class.new(project).call

        expect(result).to be_nil
      end
    end
  end

  describe ".eligible_issue_ids" do
    it "returns a Set of eligible issue IDs scoped to the given collection" do
      eligible = create(:issue, project: project, github_state: "open")
      _other = create(:issue, project: project, github_state: "open")

      result = described_class.eligible_issue_ids([ eligible ])

      expect(result).to be_a(Set)
      expect(result).to include(eligible.id)
      expect(result).not_to include(_other.id)
    end

    it "excludes issues with excluded labels" do
      planning = create(:issue, project: project, labels: [ "planning" ])
      normal = create(:issue, project: project, labels: [])

      result = described_class.eligible_issue_ids([ planning, normal ])

      expect(result).not_to include(planning.id)
      expect(result).to include(normal.id)
    end

    it "excludes parent issues that have sub-issues" do
      parent = create(:issue, project: project, github_number: 1)
      create(:issue, project: project, github_number: 2, parent_issue: parent)
      standalone = create(:issue, project: project, github_number: 3)

      result = described_class.eligible_issue_ids([ parent, standalone ])

      expect(result).not_to include(parent.id)
      expect(result).to include(standalone.id)
    end

    it "excludes issues with active agent runs" do
      with_run = create(:issue, project: project)
      create(:agent_run, :running, project: project, issue: with_run)
      without_run = create(:issue, project: project)

      result = described_class.eligible_issue_ids([ with_run, without_run ])

      expect(result).not_to include(with_run.id)
      expect(result).to include(without_run.id)
    end

    it "returns an empty set when given an empty collection" do
      result = described_class.eligible_issue_ids([])

      expect(result).to eq(Set.new)
    end

    it "excludes tracker issues with open body-referenced issues" do
      tracker = create(:issue, project: project, github_number: 413,
        title: "Remaining work tracker",
        body: "Tracks #10 and #11")
      create(:issue, project: project, github_number: 10, github_state: "open")
      create(:issue, :closed, project: project, github_number: 11)
      leaf = create(:issue, project: project, github_number: 20)

      result = described_class.eligible_issue_ids([ tracker, leaf ])

      expect(result).not_to include(tracker.id)
      expect(result).to include(leaf.id)
    end
  end
end
