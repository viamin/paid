# frozen_string_literal: true

require "rails_helper"

RSpec.describe Automation::Strategies::AutoPick::DefaultCandidateSource do
  let(:project) { create(:project, auto_pick_enabled: true) }

  describe ".next_candidate" do
    it "returns the top-ranked eligible issue for the project" do
      issue = create(:issue, project: project, github_state: "open")

      expect(described_class.next_candidate(project)).to eq(issue)
    end

    it "returns nil when the project has no eligible candidates" do
      create(:issue, project: project, labels: [ "planning" ])

      expect(described_class.next_candidate(project)).to be_nil
    end

    it "prefers higher-priority issues over lower-priority ones" do
      _p3 = create(:issue, project: project, github_number: 1, labels: [ "P3" ])
      p1 = create(:issue, project: project, github_number: 2, labels: [ "P1" ])

      expect(described_class.next_candidate(project)).to eq(p1)
    end

    it "matches configured priority labels case-insensitively" do
      project.update!(priority_labels: { "P1" => "P1", "P2" => "P2", "P3" => "P3" })
      _p3 = create(:issue, project: project, github_number: 1, labels: [ "p3" ])
      p1 = create(:issue, project: project, github_number: 2, labels: [ "p1" ])

      expect(described_class.next_candidate(project)).to eq(p1)
    end

    it "prefers runnable dependency-tree roots over standalone issues" do
      _standalone = create(:issue, project: project, github_number: 1, github_state: "open")
      blocker = create(:issue, project: project, github_number: 2, github_state: "open")
      dependent = create(:issue, project: project, github_number: 3, github_state: "open")
      create(:issue_dependency, issue: dependent, depends_on_issue: blocker)

      expect(described_class.next_candidate(project)).to eq(blocker)
    end

    it "counts open dependents from other projects in the same account" do
      other_project = create(:project, account: project.account)
      _standalone = create(:issue, project: project, github_number: 1, github_state: "open")
      blocker = create(:issue, project: project, github_number: 2, github_state: "open")
      dependent = create(:issue, project: other_project, github_number: 3, github_state: "open")
      create(:issue_dependency, issue: dependent, depends_on_issue: blocker)

      expect(described_class.next_candidate(project)).to eq(blocker)
    end

    it "does not penalize issues whose dependents are all closed" do
      former_blocker = create(:issue, project: project, github_number: 1, github_state: "open")
      _standalone = create(:issue, project: project, github_number: 2, github_state: "open")
      closed_dependent = create(:issue, project: project, github_number: 3, github_state: "closed")
      create(:issue_dependency, issue: closed_dependent, depends_on_issue: former_blocker)

      # former_blocker gets no dependency-tree boost once all dependents are closed.
      expect(described_class.next_candidate(project)).to eq(former_blocker)
    end
  end

  describe ".eligible_scope" do
    it "returns a scope limited to eligible issues" do
      eligible = create(:issue, project: project)
      create(:issue, project: project, labels: [ "planning" ])

      scope = described_class.eligible_scope(project)

      expect(scope.pluck(:id)).to contain_exactly(eligible.id)
    end

    it "includes completed issues with no PR-producing run (infrastructure failure recovery)" do
      issue = create(:issue, project: project, paid_state: "completed")
      create(:agent_run, :completed, :automatic, project: project, issue: issue,
        goal: "create_pr", auto_pick: true, pull_request_number: nil, pull_request_url: nil)

      scope = described_class.eligible_scope(project)

      expect(scope.pluck(:id)).to contain_exactly(issue.id)
    end

    it "includes completed issues when an auto-pick follow-up run completed without a PR" do
      issue = create(:issue, project: project, paid_state: "completed")
      create(:agent_run, :completed, :automatic, project: project, issue: issue,
        goal: "enhance_issue", auto_pick: true, pull_request_number: nil, pull_request_url: nil)

      scope = described_class.eligible_scope(project)

      expect(scope.pluck(:id)).to contain_exactly(issue.id)
    end

    it "excludes completed issues when the produced PR has not been synced yet" do
      issue = create(:issue, project: project, paid_state: "completed")
      create(:agent_run, :completed, :automatic, project: project, issue: issue,
        goal: "create_pr", auto_pick: true, pull_request_number: 42, pull_request_url: "https://example.test/pr/42")

      scope = described_class.eligible_scope(project)

      expect(scope.pluck(:id)).to be_empty
    end

    it "excludes completed issues when the produced PR is still open" do
      issue = create(:issue, project: project, paid_state: "completed")
      create(:agent_run, :completed, :automatic, project: project, issue: issue,
        goal: "create_pr", auto_pick: true, pull_request_number: 42, pull_request_url: "https://example.test/pr/42")
      create(:issue, project: project, github_number: 42, is_pull_request: true, github_state: "open")

      scope = described_class.eligible_scope(project)

      expect(scope.pluck(:id)).to be_empty
    end

    it "recovers completed issues when the produced PR was closed without merging" do
      issue = create(:issue, project: project, paid_state: "completed")
      create(:agent_run, :completed, :automatic, project: project, issue: issue,
        goal: "create_pr", auto_pick: true, pull_request_number: 42, pull_request_url: "https://example.test/pr/42")
      create(:issue, project: project, github_number: 42, is_pull_request: true, github_state: "closed")

      scope = described_class.eligible_scope(project)

      expect(scope.pluck(:id)).to contain_exactly(issue.id)
    end

    it "blocks recovery when one PR is closed but another is still open" do
      issue = create(:issue, project: project, paid_state: "completed")
      create(:agent_run, :completed, :automatic, project: project, issue: issue,
        goal: "create_pr", auto_pick: true, pull_request_number: 10, pull_request_url: "https://example.test/pr/10")
      create(:issue, project: project, github_number: 10, is_pull_request: true, github_state: "closed")
      create(:agent_run, :completed, project: project, issue: issue,
        goal: "create_pr", pull_request_number: 11, pull_request_url: "https://example.test/pr/11")
      create(:issue, project: project, github_number: 11, is_pull_request: true, github_state: "open")

      scope = described_class.eligible_scope(project)

      expect(scope.pluck(:id)).to be_empty
    end

    it "includes completed issues even when other PR-producing runs have NULL issue_id" do
      issue = create(:issue, project: project, paid_state: "completed")
      create(:agent_run, :completed, :automatic, project: project, issue: issue,
        goal: "create_pr", auto_pick: true, pull_request_number: nil, pull_request_url: nil)
      create(:agent_run, :completed, project: project, issue: nil, pull_request_number: 99,
        custom_prompt: "manual PR run")

      scope = described_class.eligible_scope(project)

      expect(scope.pluck(:id)).to contain_exactly(issue.id)
    end

    it "excludes completed issues whose completed run was not a recoverable auto-pick run" do
      manual_issue = create(:issue, project: project, paid_state: "completed", github_number: 50)
      analyze_issue = create(:issue, project: project, paid_state: "completed", github_number: 51)

      create(:agent_run, :completed, :manual, project: project, issue: manual_issue,
        goal: "create_pr", auto_pick: false, pull_request_number: nil, pull_request_url: nil)
      create(:agent_run, :completed, :automatic, project: project, issue: analyze_issue,
        goal: "analyze_issue", auto_pick: false, pull_request_number: nil, pull_request_url: nil)

      scope = described_class.eligible_scope(project)

      expect(scope.pluck(:id)).to be_empty
    end

    it "keeps a parent issue eligible when all of its sub-issues are closed" do
      parent = create(:issue, project: project, github_number: 1)
      create(:issue, :closed, project: project, github_number: 2, parent_issue: parent)

      scope = described_class.eligible_scope(project)

      expect(scope.pluck(:id)).to contain_exactly(parent.id)
    end

    it "excludes a parent issue while it still has open non-PR sub-issues" do
      parent = create(:issue, project: project, github_number: 1)
      child = create(:issue, project: project, github_number: 2, parent_issue: parent)
      standalone = create(:issue, project: project, github_number: 3)

      scope = described_class.eligible_scope(project)

      expect(scope.pluck(:id)).to contain_exactly(child.id, standalone.id)
    end

    it "keeps a parent eligible when its only open sub-issue is recommend_close" do
      parent = create(:issue, project: project, github_number: 1)
      create(:issue, :recommend_close, project: project, github_number: 2, parent_issue: parent)

      scope = described_class.eligible_scope(project)

      expect(scope.pluck(:id)).to include(parent.id)
    end

    it "uses project skip labels before user, tenant, and defaults" do
      project.update!(auto_pick_skip_labels: %w[blocked])
      project.created_by.settings.update!(auto_pick_skip_labels: %w[user-skip])
      project.account.tenant_setting!.update!(auto_pick_skip_labels: %w[tenant-skip])
      create(:issue, project: project, labels: [ "blocked" ])
      eligible = create(:issue, project: project, labels: [ "planning" ])

      scope = described_class.eligible_scope(project)

      expect(scope.pluck(:id)).to contain_exactly(eligible.id)
    end

    it "falls back to user skip labels when the project does not override them" do
      project.update!(auto_pick_skip_labels: nil)
      project.created_by.settings.update!(auto_pick_skip_labels: %w[user-skip])
      project.account.tenant_setting!.update!(auto_pick_skip_labels: %w[tenant-skip])
      create(:issue, project: project, labels: [ "user-skip" ])
      eligible = create(:issue, project: project, labels: [ "planning" ])

      scope = described_class.eligible_scope(project)

      expect(scope.pluck(:id)).to contain_exactly(eligible.id)
    end

    it "falls back to tenant skip labels when neither project nor user override them" do
      project.update!(auto_pick_skip_labels: nil)
      project.created_by.settings.update!(auto_pick_skip_labels: nil)
      project.account.tenant_setting!.update!(auto_pick_skip_labels: %w[tenant-skip])
      create(:issue, project: project, labels: [ "tenant-skip" ])
      eligible = create(:issue, project: project, labels: [ "planning" ])

      scope = described_class.eligible_scope(project)

      expect(scope.pluck(:id)).to contain_exactly(eligible.id)
    end

    it "falls back to the built-in skip labels when no overrides exist" do
      project.update!(auto_pick_skip_labels: nil)
      project.created_by.settings.update!(auto_pick_skip_labels: nil)
      project.account.tenant_setting!.update!(auto_pick_skip_labels: nil)
      create(:issue, project: project, labels: [ "planning" ])

      expect(described_class.eligible_scope(project)).to be_empty
    end

    it "allows an explicit empty override to disable skip labels entirely" do
      project.update!(auto_pick_skip_labels: [])
      create(:issue, project: project, labels: [ "planning" ])

      expect(described_class.eligible_scope(project).pluck(:labels)).to include([ "planning" ])
    end

    it "matches allowlist entries case-insensitively against github_creator_login" do
      project.update!(allowed_github_usernames: [ "Viamin" ])
      issue = create(:issue, project: project, github_creator_login: "viamin")

      scope = described_class.eligible_scope(project)

      expect(scope.pluck(:id)).to contain_exactly(issue.id)
    end

    it "excludes issues whose creator is not in the allowlist regardless of case" do
      project.update!(allowed_github_usernames: [ "Viamin" ])
      create(:issue, project: project, github_creator_login: "otheruser")

      scope = described_class.eligible_scope(project)

      expect(scope.pluck(:id)).to be_empty
    end
  end

  describe ".eligible_issue_ids" do
    it "returns the subset of displayed issues that are eligible" do
      eligible = create(:issue, project: project)
      planning = create(:issue, project: project, labels: [ "planning" ])

      result = described_class.eligible_issue_ids([ eligible, planning ])

      expect(result).to be_a(Set)
      expect(result).to include(eligible.id)
      expect(result).not_to include(planning.id)
    end

    it "returns an empty set when given an empty collection" do
      expect(described_class.eligible_issue_ids([])).to eq(Set.new)
    end
  end

  describe ".tracker_ids_blocked_by_open_references" do
    it "enqueues DependencyBackfillJob for referenced issues not in the database" do
      tracker = create(:issue, project: project, github_number: 1, title: "Tracker",
        body: "## Completion Criteria\n- [ ] #99\n- [ ] #100")
      _closed_ref = create(:issue, project: project, github_number: 100,
        github_state: "closed", is_pull_request: false)

      scope = Issue.where(id: tracker.id)

      allow(DependencyBackfillJob).to receive(:perform_later)

      described_class.tracker_ids_blocked_by_open_references(scope, project)

      expect(DependencyBackfillJob).to have_received(:perform_later).with(project.id, [ 99 ])
    end

    it "does not enqueue backfill when all referenced issues exist in the database" do
      tracker = create(:issue, project: project, github_number: 1, title: "Tracker",
        body: "## Completion Criteria\n- [ ] #100")
      _closed_ref = create(:issue, project: project, github_number: 100,
        github_state: "closed", is_pull_request: false)

      scope = Issue.where(id: tracker.id)

      allow(DependencyBackfillJob).to receive(:perform_later)

      described_class.tracker_ids_blocked_by_open_references(scope, project)

      expect(DependencyBackfillJob).not_to have_received(:perform_later)
    end
  end

  describe "interface compliance" do
    it "responds to every method declared by the CandidateSource interface" do
      %i[eligible_issue_ids eligible_scope next_candidate].each do |method_name|
        expect(described_class).to respond_to(method_name)
      end
    end
  end
end
