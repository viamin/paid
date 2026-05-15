# frozen_string_literal: true

require "rails_helper"

RSpec.describe Issues::AutoPick do
  let(:project) { create(:project, auto_pick_enabled: true) }

  describe "#call" do
    it "selects the auto-pick strategy through Automation::Strategies::Select" do
      selected_strategy = instance_double(Automation::Strategies::AutoPick)
      issue = create(:issue, project: project, github_state: "open")
      result = Automation::Result.new(decisions: [ Automation::Decision.queue_create_pr_run(issue_id: issue.id) ])

      allow(Automation::Strategies::Select).to receive(:call)
        .with(strategy_type: :auto_pick, project: project)
        .and_return(selected_strategy)
      allow(selected_strategy).to receive(:evaluate).and_return(result)

      described_class.new(project).call

      expect(Automation::Strategies::Select).to have_received(:call)
        .with(strategy_type: :auto_pick, project: project)
      expect(selected_strategy).to have_received(:evaluate).with(
        have_attributes(project: project)
      )
    end

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

    it "creates a create_pr run when auto_enhance_enabled is false" do
      _issue = create(:issue, project: project, github_state: "open")

      result = described_class.new(project).call

      expect(result).to be_a(AgentRun)
      expect(result.goal).to eq("create_pr")
    end

    it "creates an analyze_issue run when auto_enhance_enabled is true" do
      project.update!(auto_enhance_enabled: true)
      issue = create(:issue, project: project, github_state: "open")

      result = described_class.new(project).call

      expect(result).to be_a(AgentRun)
      expect(result.issue).to eq(issue)
      expect(result.goal).to eq("analyze_issue")
      expect(result.status).to eq("queued")
      expect(result.trigger_type).to eq("automatic")
    end

    it "returns nil when auto_pick is disabled on the project" do
      project.update!(auto_pick_enabled: false)
      create(:issue, project: project, github_state: "open")

      result = described_class.new(project).call

      expect(result).to be_nil
    end

    it "returns nil when the project quality queue is paused" do
      project.update!(quality_paused_at: Time.current)
      create(:issue, project: project, github_state: "open")

      result = described_class.new(project).call

      expect(result).to be_nil
    end

    it "returns nil when the project scheduler is paused" do
      project.update!(scheduler_paused_at: Time.current)
      create(:issue, project: project, github_state: "open")

      result = described_class.new(project).call

      expect(result).to be_nil
    end

    it "returns nil when the account scheduler is paused" do
      project.account.update!(scheduler_paused_at: Time.current)
      create(:issue, project: project, github_state: "open")

      result = described_class.new(project).call

      expect(result).to be_nil
    end

    it "returns nil when the project has no effective owner" do
      allow(project).to receive(:effective_owner).and_return(nil)
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

    it "skips issues that already have an open PR linked via parent_issue_id" do
      issue_with_pr = create(:issue, project: project, github_number: 1)
      create(:issue, :pull_request, project: project, parent_issue: issue_with_pr, github_state: "open")
      eligible = create(:issue, project: project, github_number: 2)

      result = described_class.new(project).call

      expect(result.issue).to eq(eligible)
    end

    it "returns nil when all issues have open PRs" do
      issue = create(:issue, project: project, github_number: 1)
      create(:issue, :pull_request, project: project, parent_issue: issue, github_state: "open")

      result = described_class.new(project).call

      expect(result).to be_nil
    end

    it "does not skip issues whose linked PRs are closed" do
      issue = create(:issue, project: project, github_number: 1)
      create(:issue, :pull_request, project: project, parent_issue: issue, github_state: "closed")

      result = described_class.new(project).call

      expect(result.issue).to eq(issue)
    end

    it "does not let unrelated open PRs without a parent issue suppress picking" do
      create(:issue, :pull_request, project: project, parent_issue: nil, github_state: "open")
      issue = create(:issue, project: project, github_number: 1)

      result = described_class.new(project).call

      expect(result.issue).to eq(issue)
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

    it "skips issues labeled needs-manual-setup" do
      create(:issue, project: project, labels: [ "needs-manual-setup" ])

      result = described_class.new(project).call

      expect(result).to be_nil
    end

    context "with tracker/meta issues" do
      it "skips a tracker issue when its body references open issues" do
        tracker = create(:issue, project: project, github_number: 100,
          title: "Phase 2 remaining work tracker",
          body: "## Required\n- #262 Redaction\n- #269 Security\n- #410 Search")
        redaction_issue = create(:issue, project: project, github_number: 262, github_state: "open")
        security_issue = create(:issue, project: project, github_number: 269, github_state: "open")

        result = described_class.new(project).call

        # Tracker #100 would normally be picked (lowest number), but is blocked
        # due to open body-referenced issues; one of the referenced issues is picked instead.
        expect(result.issue).not_to eq(tracker)
        expect([ redaction_issue, security_issue ]).to include(result.issue)
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

      it "skips a tracker issue when it has no body references" do
        _tracker = create(:issue, project: project, github_number: 1,
          title: "Completion criteria tracker",
          body: "Just some text with no issue refs")
        normal_issue = create(:issue, project: project, github_number: 2,
          github_state: "open", title: "Regular issue to work on")

        result = described_class.new(project).call

        # Tracker #1 would normally be picked (lowest number), but is blocked
        # because trackers with no body references are conservatively excluded.
        expect(result.issue).to eq(normal_issue)
      end

      it "blocks a tracker when body-referenced issues are not synced locally" do
        tracker = create(:issue, project: project, github_number: 413,
          title: "Phase 2 remaining work tracker",
          body: "## Required\n- #262 Redaction\n- #269 Security")
        # Neither #262 nor #269 exist in local DB (unsynced)
        normal_issue = create(:issue, project: project, github_state: "open",
          title: "Regular issue to work on")

        result = described_class.new(project).call

        # Tracker is blocked because unsynced references are treated as
        # potentially open (conservative safety net for incomplete sync).
        expect(result.issue).to eq(normal_issue)
        expect(result.issue).not_to eq(tracker)
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
        _tracker = create(:issue, project: project, github_number: 1,
          title: "Phase 2 umbrella",
          body: "## Completion criteria\n- #10 done\n- #11 done")
        next_issue = create(:issue, project: project, github_number: 10, github_state: "open")

        result = described_class.new(project).call

        # Tracker #1 would normally be picked (lowest number), but is blocked
        # due to body-based tracker detection and open body-referenced issues.
        expect(result.issue).to eq(next_issue)
      end

      it "regression: tracker with mixed explicit deps and body refs" do
        # Simulates #413 scenario: tracker with closed explicit deps but
        # still-open issues referenced in the body.
        tracker = create(:issue, project: project, github_number: 413,
          title: "Phase 2 remaining work tracker",
          body: "## Dependencies\nDepends on #410, #411\n\n## Supporting\n- #262\n- #269")
        dep_410 = create(:issue, :closed, project: project, github_number: 410)
        dep_411 = create(:issue, :closed, project: project, github_number: 411)
        create(:issue, project: project, github_number: 262, github_state: "open")
        create(:issue, project: project, github_number: 269, github_state: "open")

        # Even though explicit deps (410, 411) are closed, open body refs block the tracker
        create(:issue_dependency, issue: tracker, depends_on_issue: dep_410)
        create(:issue_dependency, issue: tracker, depends_on_issue: dep_411)

        result = described_class.new(project).call

        # Tracker is blocked because body-referenced issues #262 and #269 are
        # still open; one of those open issues is picked instead.
        expect(result.issue).not_to eq(tracker)
      end
    end

    it "picks a parent issue when all of its sub-issues are closed" do
      parent = create(:issue, project: project, github_number: 1)
      create(:issue, :closed, project: project, github_number: 3, parent_issue: parent)
      create(:issue, project: project, github_number: 2)

      result = described_class.new(project).call

      expect(result.issue).to eq(parent)
    end

    it "skips parent issues that still have open sub-issues" do
      parent = create(:issue, project: project, github_number: 1)
      create(:issue, project: project, github_number: 3, parent_issue: parent)
      standalone = create(:issue, project: project, github_number: 2)

      result = described_class.new(project).call

      expect(result.issue).to eq(standalone)
    end

    it "picks the oldest issue regardless of unblock count" do
      # leaf_b is older (lower number) but unblocks fewer issues
      leaf_b = create(:issue, project: project, github_number: 5)
      leaf_a = create(:issue, project: project, github_number: 10)
      downstream1 = create(:issue, project: project, github_number: 20)
      downstream2 = create(:issue, project: project, github_number: 21)
      downstream3 = create(:issue, project: project, github_number: 22)

      create(:issue_dependency, issue: downstream1, depends_on_issue: leaf_a)
      create(:issue_dependency, issue: downstream2, depends_on_issue: leaf_a)
      create(:issue_dependency, issue: downstream3, depends_on_issue: leaf_b)

      result = described_class.new(project).call

      # FIFO wins: leaf_b (#5) is older than leaf_a (#10)
      expect(result.issue).to eq(leaf_b)
    end

    it "picks the oldest issue regardless of tree progress" do
      # tree2_issue is older (lower number) but NOT in a started tree
      tree2_issue = create(:issue, project: project, github_number: 1)
      tree2_downstream = create(:issue, project: project, github_number: 30)
      create(:issue_dependency, issue: tree2_downstream, depends_on_issue: tree2_issue)

      # tree1_issue is newer but IS in a started tree (sibling closed)
      tree1_issue = create(:issue, project: project, github_number: 10)
      sibling_closed = create(:issue, :closed, project: project, github_number: 11)
      downstream = create(:issue, project: project, github_number: 20)
      create(:issue_dependency, issue: downstream, depends_on_issue: tree1_issue)
      create(:issue_dependency, issue: downstream, depends_on_issue: sibling_closed)

      result = described_class.new(project).call

      # FIFO wins: tree2_issue (#1) is older than tree1_issue (#10)
      expect(result.issue).to eq(tree2_issue)
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
      # github_number ASC picks C (#3) before D (#4).
      result = described_class.new(project).call
      expect(result.issue).to eq(issue_c)
    end

    context "with priority labels" do
      it "picks a P1 issue before a P2 issue" do
        p2_issue = create(:issue, project: project, github_number: 1, labels: [ "P2" ])
        p1_issue = create(:issue, project: project, github_number: 2, labels: [ "P1" ])

        result = described_class.new(project).call

        expect(result.issue).to eq(p1_issue)
        expect(result.issue).not_to eq(p2_issue)
      end

      it "picks a P1 issue before P2, P3, and unlabeled issues" do
        create(:issue, project: project, github_number: 1, labels: [])
        create(:issue, project: project, github_number: 2, labels: [ "P3" ])
        create(:issue, project: project, github_number: 3, labels: [ "P2" ])
        p1_issue = create(:issue, project: project, github_number: 4, labels: [ "P1" ])

        result = described_class.new(project).call

        expect(result.issue).to eq(p1_issue)
      end

      it "picks a P2 issue before P3 and unlabeled issues" do
        create(:issue, project: project, github_number: 1, labels: [])
        create(:issue, project: project, github_number: 2, labels: [ "P3" ])
        p2_issue = create(:issue, project: project, github_number: 3, labels: [ "P2" ])

        result = described_class.new(project).call

        expect(result.issue).to eq(p2_issue)
      end

      it "picks a P3 issue before an unlabeled issue" do
        create(:issue, project: project, github_number: 1, labels: [])
        p3_issue = create(:issue, project: project, github_number: 2, labels: [ "P3" ])

        result = described_class.new(project).call

        expect(result.issue).to eq(p3_issue)
      end

      it "picks a P1 issue even when an unlabeled issue has a lower github_number (FIFO)" do
        create(:issue, project: project, github_number: 1)
        p1_issue = create(:issue, project: project, github_number: 100, labels: [ "P1" ])

        result = described_class.new(project).call

        expect(result.issue).to eq(p1_issue)
      end

      it "falls back to github_number (FIFO) within the same priority tier" do
        earlier = create(:issue, project: project, github_number: 5, labels: [ "P1" ])
        _later = create(:issue, project: project, github_number: 10, labels: [ "P1" ])

        result = described_class.new(project).call

        expect(result.issue).to eq(earlier)
      end

      it "still skips blocked P1 issues in favor of unblocked lower-priority issues" do
        blocking = create(:issue, project: project, github_number: 1, labels: [ "P3" ])
        blocked_p1 = create(:issue, project: project, github_number: 2, labels: [ "P1" ])
        create(:issue_dependency, issue: blocked_p1, depends_on_issue: blocking)
        unblocked_p2 = create(:issue, project: project, github_number: 3, labels: [ "P2" ])

        result = described_class.new(project).call

        # Blocked P1 is ineligible, and P2 beats P3 among remaining issues.
        expect(result.issue).to eq(unblocked_p2)
      end

      it "respects custom priority label names configured on the project" do
        project.update!(priority_labels: { "P1" => "critical", "P2" => "high", "P3" => "medium" })
        create(:issue, project: project, github_number: 1, labels: [ "medium" ])
        critical_issue = create(:issue, project: project, github_number: 2, labels: [ "critical" ])

        result = described_class.new(project).call

        expect(result.issue).to eq(critical_issue)
      end

      it "treats the highest priority label as winning when multiple are present" do
        lower = create(:issue, project: project, github_number: 1, labels: [ "P2" ])
        mixed = create(:issue, project: project, github_number: 2, labels: [ "P2", "P1" ])

        result = described_class.new(project).call

        # `mixed` carries P1 — it should beat the pure P2 issue despite a higher number.
        expect(result.issue).to eq(mixed)
        expect(result.issue).not_to eq(lower)
      end
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
      allow(Provider).to receive_messages(ensure_default_for: nil, first_enabled_for_owner: nil)
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

      it "queues another run when project already has an unfinished agent run" do
        create(:agent_run, project: project, status: "queued", temporal_workflow_id: "claimed")
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

      it "returns the existing run when a concurrent picker races on the same issue" do
        # Simulates a TOCTOU race: two pickers both SELECT the same issue as
        # eligible, then both INSERT. The DB unique partial index
        # (idx_agent_runs_unique_active_issue) rejects the second INSERT.
        # AutoPick rescues RecordNotUnique and returns the first run.
        issue = create(:issue, project: project)

        existing_run = nil
        original_create = AgentRun.method(:create!)
        allow(AgentRun).to receive(:create!) do |**attrs|
          existing_run = original_create.call(**attrs)
          raise ActiveRecord::RecordNotUnique, "idx_agent_runs_unique_active_issue"
        end

        result = described_class.new(project).call

        expect(result).to eq(existing_run)
        expect(AgentRun.where(issue: issue, status: AgentRun::AUTO_PICK_BLOCKING_STATUSES).count).to eq(1)
      end

      it "returns nil when the selected issue is deleted between candidate lookup and agent-run creation" do
        # Simulates a race where the strategy selects an issue but it is
        # destroyed before the orchestrator re-loads it. The tick must not
        # raise — it should log + return nil like the duplicate_skipped path.
        issue = create(:issue, project: project)
        allow(Issue).to receive(:find_by).and_wrap_original do |original, **kwargs|
          issue.destroy! if kwargs[:id] == issue.id
          original.call(**kwargs)
        end

        expect { described_class.new(project).call }.not_to raise_error
      end
    end

    context "when project has open pull requests" do
      it "still picks an issue when project has an open PR in in_progress state" do
        create(:issue, :pull_request, :in_progress, project: project)
        issue = create(:issue, project: project)

        result = described_class.new(project).call

        expect(result).to be_a(AgentRun)
        expect(result.issue).to eq(issue)
      end

      it "still picks an issue when project has an open PR in failed state" do
        create(:issue, :pull_request, :failed, project: project)
        issue = create(:issue, project: project)

        result = described_class.new(project).call

        expect(result).to be_a(AgentRun)
        expect(result.issue).to eq(issue)
      end

      it "still picks an issue when a run is already active for an open PR" do
        pr = create(:issue, :pull_request, :in_progress, project: project)
        create(:agent_run, :running, project: project, issue: pr)
        issue = create(:issue, project: project)

        result = described_class.new(project).call

        expect(result).to be_a(AgentRun)
        expect(result.issue).to eq(issue)
      end

      it "still picks an issue when the PR is handed off and ready" do
        create(:issue, :pull_request, :in_progress,
          project: project,
          labels: [ project.automation_label_name, "paid-ready" ],
          pr_review_phase: "ready")
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

    context "with legacy Dependabot synthetic issues" do
      it "excludes legacy Dependabot issues from auto-pick" do
        create(:issue, project: project,
          source: Issue::DEPENDABOT_ALERT_SOURCE,
          github_issue_id: Issue::LEGACY_DEPENDABOT_ID_OFFSET + 42,
          github_number: 100_000_042)

        result = described_class.new(project).call

        expect(result).to be_nil
      end

      it "excludes legacy Dependabot issues even when other eligible issues exist" do
        create(:issue, project: project,
          source: Issue::DEPENDABOT_ALERT_SOURCE,
          github_issue_id: Issue::LEGACY_DEPENDABOT_ID_OFFSET + 42,
          github_number: 100_000_042)
        github_issue = create(:issue, project: project, source: Issue::GITHUB_SOURCE, github_number: 1)

        result = described_class.new(project).call

        expect(result.issue).to eq(github_issue)
      end
    end

    context "with synthetic code scanning issues" do
      it "picks code scanning issues for auto-pick" do
        cs_issue = create(:issue, project: project,
          source: Issue::SYNTHETIC_CODE_SCANNING_SOURCE,
          github_issue_id: Issue::SYNTHETIC_CODE_SCANNING_ID_OFFSET + 1667,
          github_number: 200_001_667)

        result = described_class.new(project).call

        expect(result).to be_a(AgentRun)
        expect(result.issue).to eq(cs_issue)
      end

      it "picks code scanning issues alongside regular GitHub issues" do
        github_issue = create(:issue, project: project, source: Issue::GITHUB_SOURCE, github_number: 1)
        create(:issue, project: project,
          source: Issue::SYNTHETIC_CODE_SCANNING_SOURCE,
          github_issue_id: Issue::SYNTHETIC_CODE_SCANNING_ID_OFFSET + 1667,
          github_number: 200_001_667)

        result = described_class.new(project).call

        # GitHub issue has lower github_number, so it should be picked first
        expect(result.issue).to eq(github_issue)
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

    it "excludes issues with open PRs linked via parent_issue_id" do
      with_pr = create(:issue, project: project, github_number: 1)
      create(:issue, :pull_request, project: project, parent_issue: with_pr, github_state: "open")
      without_pr = create(:issue, project: project, github_number: 2)

      result = described_class.eligible_issue_ids([ with_pr, without_pr ])

      expect(result).not_to include(with_pr.id)
      expect(result).to include(without_pr.id)
    end

    it "includes issues whose linked PRs are closed" do
      with_closed_pr = create(:issue, project: project, github_number: 1)
      create(:issue, :pull_request, project: project, parent_issue: with_closed_pr, github_state: "closed")

      result = described_class.eligible_issue_ids([ with_closed_pr ])

      expect(result).to include(with_closed_pr.id)
    end

    it "does not exclude issues because of open PRs without a parent issue" do
      create(:issue, :pull_request, project: project, parent_issue: nil, github_state: "open")
      issue = create(:issue, project: project, github_number: 1)

      result = described_class.eligible_issue_ids([ issue ])

      expect(result).to include(issue.id)
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
