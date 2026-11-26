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

  def create_dependency_held_issues(project)
    blocker = create(:issue, project:, github_state: "open", paid_state: "new")
    issues = Array.new(Dashboard::HeldWorkDetails::MAX_HELD_ISSUES + 1) do
      create(:issue, project:, github_state: "open", paid_state: "new") do |issue|
        create(:issue_dependency, issue:, depends_on_issue: blocker)
      end
    end
    { blocker:, issues: }
  end

  def create_no_progress_runs(issue)
    revisions = {
      "source_revision" => PartialCloseouts::Assessment.source_revision_for(issue),
      "intent_revision" => PartialCloseouts::Assessment.intent_revision_for(issue),
      "outcome" => "recommend_close"
    }
    Array.new(2) do
      create(:agent_run, :completed, :automatic, project: issue.project, issue:,
        goal: "create_pr", auto_pick: true, pull_request_number: nil, result_commit_sha: nil,
        reconciliation: { "no_progress" => revisions })
    end
  end

  def with_normal_rls_role
    skip "requires CREATE ROLE privilege for normal-role RLS coverage" unless can_manage_roles?

    role = "paid_dashboard_rls_#{Process.pid}_#{SecureRandom.hex(4)}"
    quoted_role = ActiveRecord::Base.connection.quote_table_name(role)
    connection = ActiveRecord::Base.connection
    connection.transaction(requires_new: true) do
      connection.execute("CREATE ROLE #{quoted_role} NOLOGIN NOSUPERUSER NOBYPASSRLS")
      expect(connection.select_value("SELECT relrowsecurity FROM pg_class WHERE oid = 'issues'::regclass")).to be(true)
      expect(
        connection.select_value("SELECT rolsuper OR rolbypassrls FROM pg_roles WHERE rolname = #{connection.quote(role)}")
      ).to be(false)
      connection.execute("GRANT USAGE ON SCHEMA public TO #{quoted_role}")
      connection.execute("GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO #{quoted_role}")
      connection.execute("GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO #{quoted_role}")
      connection.execute("GRANT #{quoted_role} TO current_user")
      connection.execute("SET ROLE #{quoted_role}")

      yield
    ensure
      TenantContext.clear!
      connection.execute("RESET ROLE")
      connection.execute("DROP OWNED BY #{quoted_role}")
      connection.execute("DROP ROLE IF EXISTS #{quoted_role}")
    end
  end

  def can_manage_roles?
    ActiveModel::Type::Boolean.new.cast(
      ActiveRecord::Base.connection.select_value(<<~SQL.squish)
        SELECT rolcreaterole
        FROM pg_roles
        WHERE rolname = current_user
      SQL
    )
  end

  def held_work_projection(breakdowns)
    breakdowns.map do |breakdown|
      [
        breakdown.project.id,
        breakdown.held_issues.map do |held_issue|
          [
            held_issue.issue.id,
            held_issue.blockers.map { |blocker| [ blocker.label, blocker.url ] },
            held_issue.actions.map { |action| [ action.label, action.inbox_kind, action.entry_id ] },
            held_issue.diagnostic
          ]
        end
      ]
    end
  end

  def create_held_work_scope_fixtures
    local_blocker = create(:issue, project:, github_state: "open", paid_state: "new")
    local_held = create(:issue, project:, github_state: "open", paid_state: "new")
    create(:issue_dependency, issue: local_held, depends_on_issue: local_blocker)
    deployment_target = create(:issue, :closed, :pull_request, project:, paid_state: "new")
    deployment_held = create(:issue, project:, github_state: "open", paid_state: "new")
    create(:issue_dependency, issue: deployment_held, depends_on_issue: deployment_target, requires_deployment: true)
    external_held = create(:issue, project:, github_state: "open", paid_state: "new")
    create(:issue_dependency, issue: external_held, depends_on_issue: nil,
      depends_on_owner: "example", depends_on_repo: "external", depends_on_number: 42)
    feature_held = create(:issue, project:, github_state: "open", paid_state: "new")
    feature_intent = create(:feature_intent, project:, status: "design_open", approved_design_revision: nil)
    create(:feature_intent_issue, feature_intent:, issue: feature_held)
    confidence_feature_held = create(:issue, project:, github_state: "open", paid_state: "new")
    confidence_feature_intent = create(:feature_intent, :confidence_driven, project:)
    create(:feature_intent_issue, feature_intent: confidence_feature_intent,
      issue: confidence_feature_held, release_state: "held")
    amendment_held = create(:issue, project:, github_state: "open", paid_state: "new")
    create(:design_amendment_pause, design_amendment: create(:design_amendment, project:), issue: amendment_held)
    create_no_progress_runs(create(:issue, project:, github_state: "open", paid_state: "new"))

    { feature_held:, confidence_feature_held: }
  end

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

    # @spec QUEUE-HANDOFF-002
    it "reports source-closure recovery as active work" do
      issue = create(:issue, project: project, github_state: "open", paid_state: "in_progress")
      create(:agent_run, project: project, issue: issue, status: "waiting_recovery")

      breakdown = described_class.call(user: user).sole

      expect(breakdown.active).to eq(1)
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
          actions: []
        )
      )
    end

    # @spec QUEUE-HANDOFF-004
    it "preserves deployment and external dependency blockers" do
      deployment_target = create(:issue, :closed, :pull_request, project: project, paid_state: "new", pr_review_phase: "merged")
      deployment_held = create(:issue, project: project, github_state: "open", paid_state: "new")
      create(:issue_dependency, issue: deployment_held, depends_on_issue: deployment_target, requires_deployment: true)
      external_held = create(:issue, project: project, github_state: "open", paid_state: "new")
      create(:issue_dependency, issue: external_held, depends_on_issue: nil,
        depends_on_owner: "example", depends_on_repo: "external", depends_on_number: 42)

      held_issues = described_class.call(user: user).sole.held_issues.index_by { |detail| detail.issue.id }

      expect(held_issues.fetch(deployment_held.id).blockers).to contain_exactly(
        have_attributes(label: "##{deployment_target.github_number} #{deployment_target.title} (awaiting deployment)", url: deployment_target.github_url)
      )
      expect(held_issues.fetch(external_held.id).blockers).to contain_exactly(
        have_attributes(label: "example/external#42 (external dependency)", url: "https://github.com/example/external/issues/42")
      )
    end

    # @spec QUEUE-HANDOFF-004
    it "bounds held issue selection before loading dependency provenance" do
      first = create_dependency_held_issues(project)
      second_project = create(:project, account: account, created_by: user, auto_pick_enabled: true, active: true)
      second = create_dependency_held_issues(second_project)

      details_by_project = described_class.call(user: user).to_h { |breakdown| [ breakdown.project, breakdown.held_issues ] }

      expect(details_by_project.fetch(project).map { |detail| detail.issue.github_number }).to eq(
        first.fetch(:issues).first(Dashboard::HeldWorkDetails::MAX_HELD_ISSUES).map(&:github_number)
      )
      expect(details_by_project.fetch(second_project).map { |detail| detail.issue.github_number }).to eq(
        second.fetch(:issues).first(Dashboard::HeldWorkDetails::MAX_HELD_ISSUES).map(&:github_number)
      )
      expect(details_by_project.fetch(project)).to all(have_attributes(blockers: [ have_attributes(url: first.fetch(:blocker).github_url) ]))
      expect(details_by_project.fetch(second_project)).to all(have_attributes(blockers: [ have_attributes(url: second.fetch(:blocker).github_url) ]))
    end

    # @spec QUEUE-HANDOFF-004
    it "reuses the materialized held-work exclusion for ranking, blockers, and actions" do
      create_dependency_held_issues(project)

      queries = capture_queries { described_class.call(user: user) }
      held_work_query = queries.find { |query| query.include?("WITH excluded_issues AS MATERIALIZED") }

      expect(held_work_query).to include("WITH excluded_issues AS MATERIALIZED")
      expect(held_work_query.scan("WITH excluded_issues AS MATERIALIZED").size).to eq(1)
      expect(held_work_query).to include("FROM excluded_issues AS issues")
      expect(held_work_query.scan("FROM excluded_issues").size).to eq(7)
    end

    # @spec QUEUE-HANDOFF-004
    it "preserves held-work details under normal-role RLS" do
      fixtures = create_held_work_scope_fixtures

      expected_breakdowns = described_class.call(user:)
      expected = held_work_projection(expected_breakdowns)
      held_issue_ids = expected_breakdowns.sole.held_issues.map { |detail| detail.issue.id }
      expect(held_issue_ids).to include(
        fixtures.fetch(:feature_held).id,
        fixtures.fetch(:confidence_feature_held).id
      )
      Rails.cache.clear

      with_normal_rls_role do
        expect(ActiveRecord::Base.connection.select_value("SELECT current_user")).to start_with("paid_dashboard_rls_")
        expect(held_work_projection(TenantContext.with(account) { described_class.call(user:) })).to eq(expected)
      end
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
          actions: contain_exactly(
            have_attributes(
              label: "Review feature decision: #{feature_intent.title}",
              inbox_kind: Inbox::Queue::FEATURE_DECISION_KIND,
              entry_id: "#{Inbox::Queue::FEATURE_DECISION_KIND}:#{feature_intent.id}"
            )
          )
        )
      )
    end

    # @spec NO-OUTPUT-ISSUE-009
    it "projects repeated no-progress diagnostics for held Queue work" do
      issue = create(:issue, project: project, github_state: "open", paid_state: "new")
      runs = create_no_progress_runs(issue)

      held_issue = described_class.call(user: user).sole.held_issues.sole

      expect(held_issue).to have_attributes(
        issue: issue,
        blockers: [],
        actions: [],
        diagnostic: {
          reason: "repeated_no_progress_create_pr",
          run_ids: runs.map(&:id),
          next_action: "Update acceptance evidence or request an authorized retry."
        }
      )
    end

    # @spec QUEUE-HANDOFF-004
    it "carries every owning decision for an issue held by features and an amendment" do
      issue = create(:issue, project: project, github_state: "open", paid_state: "new")
      feature_intents = Array.new(2) do
        create(:feature_intent, project: project, status: "design_open", approved_design_revision: nil)
      end
      feature_intents.each { |feature_intent| create(:feature_intent_issue, feature_intent:, issue:) }
      amendment = create(:design_amendment, project: project)
      create(:design_amendment_pause, design_amendment: amendment, issue: issue)

      held_issue = described_class.call(user: user).sole.held_issues.sole

      expect(held_issue.actions).to contain_exactly(
        have_attributes(label: "Review the design amendment hold in the issue", inbox_kind: nil, entry_id: nil),
        *feature_intents.map do |feature_intent|
          have_attributes(
            label: "Review feature decision: #{feature_intent.title}",
            inbox_kind: Inbox::Queue::FEATURE_DECISION_KIND,
            entry_id: "#{Inbox::Queue::FEATURE_DECISION_KIND}:#{feature_intent.id}"
          )
        end
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

    def held_work_queries(queries)
      queries.count do |sql|
        sql.start_with?('SELECT "issue_dependencies"') ||
          sql.match?(/\ASELECT "design_amendment_pauses"\."issue_id".*WHERE "design_amendment_pauses"\."issue_id" IN/) ||
          sql.start_with?('SELECT "feature_intent_issues"."issue_id", "feature_intents"."id"') ||
          sql.match?(/\ASELECT "issues"\.\* FROM "issues" WHERE .*"issues"\."id" IN/)
      end
    end

    def create_held_projects(count, prefix)
      Array.new(count) do |i|
        create(:project, account: account, created_by: user,
          auto_pick_enabled: true, active: true, owner: "org", repo: "#{prefix}-#{i}")
      end.each do |held_project|
        create(:issue, project: held_project, github_state: "open", paid_state: "new") do |issue|
          blocker = create(:issue, project: held_project, github_state: "open", paid_state: "new")
          create(:issue_dependency, issue:, depends_on_issue: blocker)
        end
      end
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

    it "resolves held-work provenance with a project-independent query count" do
      create(:issue, project: project, github_state: "open", paid_state: "new") do |issue|
        blocker = create(:issue, project: project, github_state: "open", paid_state: "new")
        create(:issue_dependency, issue:, depends_on_issue: blocker)
      end
      create_held_projects(3, "held-repo")
      initial_queries = held_work_queries(capture_queries { described_class.call(user: user) })

      Rails.cache.clear
      create_held_projects(3, "more-held-repo")
      expanded_queries = held_work_queries(capture_queries { described_class.call(user: user) })

      expect(initial_queries).to be_positive
      expect(expanded_queries).to eq(initial_queries)
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
