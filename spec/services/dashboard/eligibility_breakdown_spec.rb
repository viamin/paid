# frozen_string_literal: true

require "rails_helper"

RSpec.describe Dashboard::EligibilityBreakdown do
  around do |example|
    original_store = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    example.run
  ensure
    Rails.cache = original_store
  end

  let(:user) { create(:user) }
  let(:account) { user.account }
  let!(:project) do
    create(:project, account: account, created_by: user, auto_pick_enabled: true, active: true)
  end

  before { Rails.cache.clear }

  describe ".call" do
    # @spec QUEUE-HANDOFF-001 QUEUE-HANDOFF-002
    it "reports an unseeded eligible issue even with unrelated queued and active work" do
      unseeded = create(:issue, project: project, github_state: "open", paid_state: "new")
      active = create(:issue, project: project, github_state: "open", paid_state: "new")
      create(:agent_run, :queued, :with_custom_prompt, project: project)
      create(:agent_run, :running, project: project, issue: active)

      breakdown = described_class.call(user: user).sole

      # The canonical candidate scope intentionally excludes issues already
      # claimed by queued/active work; its remaining candidate is the stalled
      # handoff that needs seeding.
      expect(breakdown.eligible).to eq(1)
      expect(breakdown.queued).to eq(1)
      expect(breakdown.active).to eq(1)
      expect(breakdown.unseeded).to eq(1)
      expect(breakdown.diagnostic_state).to eq(:runnable_not_seeded)
      expect(unseeded).to be_persisted
    end

    # @spec QUEUE-HANDOFF-002
    it "reports healthy active work without a waiting backlog" do
      issue = create(:issue, project: project, github_state: "open", paid_state: "new")
      create(:agent_run, :running, project: project, issue: issue)

      breakdown = described_class.call(user: user).sole

      expect(breakdown.unseeded).to eq(0)
      expect(breakdown.diagnostic_state).to eq(:active_work)
    end

    it "returns an empty array when user has no auto-pick projects" do
      project.update!(auto_pick_enabled: false)

      result = described_class.call(user: user)

      expect(result).to eq([])
    end

    it "returns a breakdown with correct counts" do
      create(:issue, project: project, github_state: "open", paid_state: "new")
      create(:issue, project: project, github_state: "open", paid_state: "new", labels: [ "tracking" ])
      create(:issue, project: project, github_state: "open", paid_state: "needs_input", needs_input_questions: [ "What should happen?" ])
      create(:issue, project: project, github_state: "open", paid_state: "in_progress")
      create(:issue, project: project, github_state: "open", paid_state: "completed")
      create(:issue, project: project, github_state: "open", paid_state: "manual_review", manual_review_reason: "Round limit reached.")

      result = described_class.call(user: user)

      expect(result.size).to eq(1)
      bd = result.first
      expect(bd.project).to eq(project)
      expect(bd.total_open).to eq(6)
      expect(bd.eligible).to eq(5)
      expect(bd.needs_input).to eq(0)
      expect(bd.in_progress).to eq(0)
      expect(bd.completed).to eq(0)
      expect(bd.manual_review).to eq(0)
      expect(bd.skip_label).to eq(1)
      expect(bd.other_excluded).to eq(0)
    end

    # @spec OPERATOR-INBOX-002D
    it "does not count manual_review as excluded solely because of internal state" do
      create(:issue, project: project, github_state: "open", paid_state: "manual_review", manual_review_reason: "Round limit reached.")

      result = described_class.call(user: user)

      bd = result.first
      expect(bd.eligible).to eq(1)
      expect(bd.manual_review).to eq(0)
      expect(bd.other_excluded).to eq(0)
    end

    it "does not exclude questionless needs-input issues solely because of internal state" do
      create(:issue, project: project, github_state: "open", paid_state: "needs_input")

      result = described_class.call(user: user)

      bd = result.first
      expect(bd.eligible).to eq(1)
      expect(bd.needs_input).to eq(0)
      expect(bd.other_excluded).to eq(0)
    end

    it "does not exclude marker-only needs-input issues solely because of internal state" do
      create(:issue, project: project, github_state: "open", paid_state: "needs_input",
        body: "#{ClarifyingQuestions::Parse::ENHANCEMENT_MARKER}\n\n## Clarifying questions\nNo numbered questions here.")

      result = described_class.call(user: user)

      bd = result.first
      expect(bd.eligible).to eq(1)
      expect(bd.needs_input).to eq(0)
      expect(bd.other_excluded).to eq(0)
    end

    # @spec QUEUE-HANDOFF-004
    it "carries every dependency blocker for held issues" do
      blocker = create(:issue, project: project, github_state: "open", paid_state: "new")
      second_blocker = create(:issue, project: project, github_state: "open", paid_state: "new")
      dependent = create(:issue, project: project, github_state: "open", paid_state: "new") do |dependent|
        create(:issue_dependency, issue: dependent, depends_on_issue: blocker)
        create(:issue_dependency, issue: dependent, depends_on_issue: second_blocker)
      end

      result = described_class.call(user: user)

      bd = result.first
      expect(bd.eligible).to eq(2)
      expect(bd.other_excluded).to eq(1)
      expect(bd.held_issues).to contain_exactly(
        have_attributes(
          issue: have_attributes(github_number: dependent.github_number),
          blockers: contain_exactly(
            have_attributes(label: "##{blocker.github_number} #{blocker.title}", url: blocker.github_url),
            have_attributes(label: "##{second_blocker.github_number} #{second_blocker.title}", url: second_blocker.github_url)
          ),
          action: nil
        )
      )
    end

    # @spec QUEUE-HANDOFF-004
    it "carries the existing Inbox action for feature-decision holds" do
      issue = create(:issue, project: project, github_state: "open", paid_state: "new")
      feature_intent = create(:feature_intent, project: project, status: "design_open", approved_design_revision: nil)
      create(:feature_intent_issue, feature_intent: feature_intent, issue: issue)

      breakdown = described_class.call(user: user).sole

      expect(breakdown.held_issues).to contain_exactly(
        have_attributes(
          issue: issue,
          blockers: [],
          action: have_attributes(
            label: "Review feature decision: #{feature_intent.title}",
            inbox_kind: Inbox::Queue::FEATURE_DECISION_KIND,
            entry_id: "#{Inbox::Queue::FEATURE_DECISION_KIND}:#{feature_intent.id}"
          )
        )
      )
    end

    it "does not double-count recoverable-completed issues in both eligible and completed" do
      issue = create(:issue, project: project, github_state: "open", paid_state: "completed")
      create(:agent_run, :completed, :automatic, project: project, issue: issue,
        goal: "create_pr", auto_pick: true, pull_request_number: nil, pull_request_url: nil)

      result = described_class.call(user: user)

      bd = result.first
      expect(bd.eligible).to eq(1)
      expect(bd.completed).to eq(0)
      expect(bd.total_open).to eq(1)
    end

    # @spec QUEUE-HANDOFF-003
    it "reports scheduler-paused projects as deliberate pauses" do
      project.update!(scheduler_paused_at: Time.current)

      result = described_class.call(user: user)

      expect(result.sole.diagnostic_state).to eq(:paused)
    end

    # @spec QUEUE-HANDOFF-003
    it "reports account-level scheduler pauses without calling them a stall" do
      account.update!(scheduler_paused_at: Time.current)

      result = described_class.call(user: user)

      expect(result.sole.diagnostic_state).to eq(:paused)
    end

    # @spec QUEUE-HANDOFF-003
    it "reports quality-paused projects as deliberate pauses" do
      project.update!(quality_paused_at: Time.current)

      result = described_class.call(user: user)

      expect(result.sole.diagnostic_state).to eq(:paused)
    end

    # @spec QUEUE-HANDOFF-003
    it "reports an operator-paused project even when its automatic run is held" do
      create(:issue, project: project, github_state: "open", paid_state: "new")
      create(:agent_run, :queued, :automatic, project: project)
      project.pause!

      breakdown = described_class.call(user: user).sole

      expect(breakdown.queued).to eq(1)
      expect(breakdown.diagnostic_state).to eq(:paused)
    end

    # @spec QUEUE-HANDOFF-002
    it "counts queued manual, closed-issue, and pull-request runs" do
      create(:agent_run, :queued, :with_custom_prompt, project: project)
      create(:agent_run, :queued, project: project,
        issue: create(:issue, project: project, github_state: "closed"))
      create(:agent_run, :queued, :existing_pr, project: project)

      breakdown = described_class.call(user: user).sole

      expect(breakdown.queued).to eq(3)
      expect(breakdown.diagnostic_state).to eq(:waiting)
    end

    # @spec QUEUE-HANDOFF-003
    it "reports paused runs as deliberately paused work" do
      issue = create(:issue, project: project, github_state: "open", paid_state: "new")
      create(:agent_run, :paused, project: project, issue: issue)

      breakdown = described_class.call(user: user).sole

      expect(breakdown.paused).to eq(1)
      expect(breakdown.diagnostic_state).to eq(:paused)
    end

    # @spec QUEUE-HANDOFF-003
    it "reports a paused run when the project also has queued work" do
      paused_issue = create(:issue, project: project, github_state: "open", paid_state: "new")
      create(:agent_run, :paused, project: project, issue: paused_issue)
      create(:agent_run, :queued, :with_custom_prompt, project: project)

      breakdown = described_class.call(user: user).sole

      expect(breakdown.queued).to eq(1)
      expect(breakdown.paused).to eq(1)
      expect(breakdown.diagnostic_state).to eq(:paused)
    end

    # @spec QUEUE-HANDOFF-003
    it "reports a paused run when the project also has active work" do
      paused_issue = create(:issue, project: project, github_state: "open", paid_state: "new")
      active_issue = create(:issue, project: project, github_state: "open", paid_state: "new")
      create(:agent_run, :paused, project: project, issue: paused_issue)
      create(:agent_run, :running, project: project, issue: active_issue)

      breakdown = described_class.call(user: user).sole

      expect(breakdown.active).to eq(1)
      expect(breakdown.paused).to eq(1)
      expect(breakdown.diagnostic_state).to eq(:paused)
    end

    it "excludes inactive projects" do
      project.update!(active: false)

      result = described_class.call(user: user)

      expect(result).to eq([])
    end

    it "excludes projects with no effective owner (auto-pick would always skip them)" do
      allow(Issues::AutoPickProjectGate).to receive(:call).with(project).and_return(false)

      result = described_class.call(user: user)

      expect(result).to eq([])
    end

    it "handles multiple projects in a single call" do
      project2 = create(:project, account: account, created_by: user,
        auto_pick_enabled: true, active: true, owner: "org", repo: "repo2")
      create(:issue, project: project, github_state: "open", paid_state: "new")
      create(:issue, project: project2, github_state: "open", paid_state: "new")

      result = described_class.call(user: user)

      expect(result.size).to eq(2)
      expect(result.map { |bd| bd.project.id }).to contain_exactly(project.id, project2.id)
    end

    it "does not issue a per-project query for owner or owner settings (no N+1)" do
      extra_projects = Array.new(3) do |i|
        create(:project, account: account, created_by: user,
          auto_pick_enabled: true, active: true, owner: "org", repo: "repo-#{i}")
      end
      # analyzable excluded issues force the skip-label lookup path, which is
      # where a per-project +user_setting+/+tenant_setting+ load would leak in.
      ([ project ] + extra_projects).each do |p|
        create(:issue, project: p, github_state: "open", paid_state: "new")
      end

      queries = capture_queries { described_class.call(user: user) }

      # All projects share one owner, so a working preload issues owner/owner-
      # setting queries at most once each. An N+1 would repeat the identical
      # query once per project. Detect repeats rather than SQL shape: Rails
      # collapses a single-value preload to `WHERE id = $1`, which is
      # indistinguishable from a lazy belongs_to lookup by shape alone.
      owner_queries = queries.select do |sql|
        sql.match?(/FROM "users" WHERE "users"\."id" = /) ||
          sql.match?(/FROM "user_settings" WHERE "user_settings"\."user_id" = /)
      end
      max_repeats = owner_queries.tally.values.max.to_i

      expect(max_repeats).to be <= 1
    end

    # The runner candidate set AUTO-PICK-QUEUE-011 resolves tier feasibility
    # from, loaded once per resolution — so its count is the resolution count.
    def feasibility_resolutions(queries)
      queries.count { |sql| sql.match?(/FROM "runners" WHERE .*enabled_for_agent_runs/) }
    end

    def handoff_count_queries(queries)
      queries.count { |sql| sql.match?(/GROUP BY "agent_runs"\."project_id", "agent_runs"\."status"/) }
    end

    it "does not resolve tier feasibility per project (no N+1)" do
      create(:issue, project: project, github_state: "open", paid_state: "new")
      single_repo_resolutions = feasibility_resolutions(capture_queries { described_class.call(user: user) })

      Rails.cache.clear
      Array.new(3) do |i|
        create(:project, account: account, created_by: user,
          auto_pick_enabled: true, active: true, owner: "org", repo: "tier-repo-#{i}")
      end.each do |p|
        create(:issue, project: p, github_state: "open", paid_state: "new")
      end
      multi_repo_resolutions = feasibility_resolutions(capture_queries { described_class.call(user: user) })

      expect(single_repo_resolutions).to be_positive
      expect(multi_repo_resolutions).to eq(single_repo_resolutions)
    end

    it "resolves handoff counts for all visible projects in one query" do
      create(:agent_run, :queued, project: project)
      single_query_count = handoff_count_queries(capture_queries { described_class.call(user: user) })

      Rails.cache.clear
      Array.new(3) do |i|
        create(:project, account: account, created_by: user,
          auto_pick_enabled: true, active: true, owner: "org", repo: "handoff-repo-#{i}")
      end.each { |additional_project| create(:agent_run, :queued, project: additional_project) }
      multi_query_count = handoff_count_queries(capture_queries { described_class.call(user: user) })

      expect(single_query_count).to eq(1)
      expect(multi_query_count).to eq(single_query_count)
    end

    it "includes orphaned projects for the account fallback owner" do
      orphaned_project = create(:project, :without_creator, account: account,
        auto_pick_enabled: true, active: true, owner: "octo", repo: "orphaned")
      create(:issue, project: orphaned_project, github_state: "open", paid_state: "new")

      result = described_class.call(user: user)

      expect(result.map { |bd| bd.project.id }).to contain_exactly(project.id, orphaned_project.id)
    end

    it "hides orphaned projects from non-fallback users" do
      non_fallback_user = create(:user, account: account)
      non_fallback_project = create(:project, account: account, created_by: non_fallback_user,
        auto_pick_enabled: true, active: true, owner: "octo", repo: "owned")
      orphaned_project = create(:project, :without_creator, account: account,
        auto_pick_enabled: true, active: true, owner: "octo", repo: "orphaned")
      create(:issue, project: non_fallback_project, github_state: "open", paid_state: "new")
      create(:issue, project: orphaned_project, github_state: "open", paid_state: "new")

      result = described_class.call(user: non_fallback_user)

      expect(result.map { |bd| bd.project.id }).to eq([ non_fallback_project.id ])
    end

    it "reuses the cached breakdown on repeat page loads" do
      create(:issue, project: project, github_state: "open", paid_state: "new")
      allow(Automation::Strategies::AutoPick::DefaultCandidateSource)
        .to receive(:eligible_scope).and_call_original

      described_class.call(user: user)
      described_class.call(user: user)

      expect(Automation::Strategies::AutoPick::DefaultCandidateSource)
        .to have_received(:eligible_scope).once
    end
  end
end
