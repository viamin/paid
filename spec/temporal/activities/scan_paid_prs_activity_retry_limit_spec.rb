# frozen_string_literal: true

require "rails_helper"

RSpec.describe Activities::ScanPaidPrsActivity do
  describe "#scan_pr retry-limit phase handling", :no_db do
    let(:activity) { described_class.new }
    let(:project) { instance_double(ProjectDouble) }
    let(:client) { instance_double(GithubClientDouble) }
    let(:progress_state) { instance_double(ProgressStateDouble) }
    let(:issue) do
      instance_double(IssueDouble,
        pr_review_phase: phase,
        id: 123,
        github_number: 42,
        github_creator_login: "paid-bot",
        review_goal_retry_count: 0,
        project: project)
    end

    before do
      stub_const("ProjectDouble", Class.new)
      stub_const("GithubClientDouble", Class.new)
      stub_const("ProgressStateDouble", Class.new do
        def latest_unsuccessful_review?; end
        def escalation_worthy?(limit:); end
      end)
      stub_const("IssueDouble", Class.new)
      stub_const("PrDataDouble", Class.new do
        def [](key); end
      end)
      stub_const("PrHeadDouble", Class.new)

      allow(activity).to receive_messages(
        pr_progress_state: progress_state,
        escalate_trigger: :unexpected_escalation
      )
      allow(activity).to receive(:backfill_review_goal_retry_reset_at!).with(issue)
      allow(activity).to receive(:pr_progress_state).with(project, issue,
        current_head_sha: anything,
        current_head_updated_at: anything).and_return(progress_state)
      allow(activity).to receive(:pr_head_commit_timestamp).with(client, project, issue, anything).and_return(Time.current)
      allow(activity).to receive(:record_focus_resolution).with(project, client, issue)
      allow(activity).to receive(:active_run_exists?).with(project, issue).and_return(false)
      allow(activity).to receive(:failure_streak_limit_reached?).with(project, issue).and_return(false)
      allow(activity).to receive(:operational_failure_breaker?).with(project, issue, progress_state).and_return(false)
      allow(activity).to receive(:review_goal_retry_needed?).with(project, issue, progress_state:).and_return(true)
      allow(activity).to receive(:review_goal_retry_limit_reached?).with(project, issue, progress_state:).and_return(true)
      allow(activity).to receive(:review_goal_retry_limit_requires_escalation?).with(project, issue, progress_state:).and_return(true)
      allow(activity).to receive(:review_goal_consecutive_failure_count).with(project, issue, progress_state:).and_return(3)
      allow(activity).to receive(:check_rate_budget!).with(client)
      allow(activity).to receive(:fetch_pr_data)
      allow(activity).to receive(:escalation_dismissed?).with(issue).and_return(false)
    end

    context "when a restarted PR already has an active create_pr run" do
      let(:phase) { "restarted" }

      it "skips before backfilling the retry reset boundary" do
        allow(activity).to receive(:active_run_exists?).with(project, issue).and_return(true)

        result = activity.send(:scan_pr, project, client, issue)

        expect(result).to eq(:skipped)
        expect(activity).to have_received(:record_focus_resolution).with(project, client, issue)
        expect(activity).to have_received(:active_run_exists?).with(project, issue)
        expect(activity).not_to have_received(:backfill_review_goal_retry_reset_at!)
      end
    end

    context "when the PR is still in draft" do
      let(:phase) { "draft" }
      let(:head_commit_timestamp) { 2.hours.ago }
      let(:pr_data) do
        instance_double(PrDataDouble,
          draft: true,
          head: instance_double(PrHeadDouble, sha: "abc123"),
          updated_at: Time.current)
      end

      before do
        allow(activity).to receive(:pr_head_commit_timestamp)
          .with(client, project, issue, pr_data)
          .and_return(head_commit_timestamp)
      end

      it "fetches live PR state before escalating at the retry limit" do
        allow(activity).to receive(:fetch_pr_data).with(client, project, issue).and_return(pr_data)
        allow(activity).to receive(:escalate_trigger).with(issue,
          reason: "Review-goal retry limit reached (3 consecutive failures)").and_return(:escalated)

        result = activity.send(:scan_pr, project, client, issue)

        expect(result).to eq(:escalated)
        expect(activity).to have_received(:fetch_pr_data).with(client, project, issue)
      end

      it "passes head-commit time rather than PR updated_at into progress_state" do
        allow(activity).to receive(:fetch_pr_data).with(client, project, issue).and_return(pr_data)
        allow(activity).to receive(:pr_progress_state).with(
          project,
          issue,
          current_head_sha: "abc123",
          current_head_updated_at: head_commit_timestamp
        ).and_return(progress_state)
        allow(activity).to receive(:escalate_trigger).with(issue,
          reason: "Review-goal retry limit reached (3 consecutive failures)").and_return(:escalated)

        activity.send(:scan_pr, project, client, issue)

        expect(activity).to have_received(:pr_progress_state).with(
          project,
          issue,
          current_head_sha: "abc123",
          current_head_updated_at: head_commit_timestamp
        )
      end
    end

    context "when the PR is restarted with stale failures from before the reset boundary" do
      let(:phase) { "restarted" }
      let(:pr_data) do
        instance_double(PrDataDouble,
          draft: true,
          head: instance_double(PrHeadDouble, sha: "restart123"),
          updated_at: Time.current)
      end

      it "backfills first and avoids escalating on stale pre-restart failures" do
        allow(activity).to receive(:backfill_review_goal_retry_reset_at!).with(issue)
        allow(activity).to receive(:failure_streak_limit_reached?).with(project, issue).and_return(true)
        allow(activity).to receive(:fetch_pr_data).with(client, project, issue).and_return(pr_data)
        allow(activity).to receive(:pr_progress_state).with(
          project,
          issue,
          current_head_sha: "restart123",
          current_head_updated_at: anything
        ).and_return(progress_state)
        allow(activity).to receive(:failure_streak_limit_reached?).with(project, issue, progress_state).and_return(false)
        allow(activity).to receive(:review_goal_retry_needed?).with(project, issue, progress_state:).and_return(false)
        allow(activity).to receive(:maybe_advance_to_ready).with(project, issue, pr_data).and_return(false)
        allow(activity).to receive(:scan_draft_pr).with(project, client, issue, pr_data: pr_data).and_return(:draft_scan)

        result = activity.send(:scan_pr, project, client, issue)

        expect(result).to eq(:draft_scan)
        expect(activity).to have_received(:backfill_review_goal_retry_reset_at!).with(issue).ordered
        expect(activity).to have_received(:failure_streak_limit_reached?).with(project, issue).ordered
        expect(activity).not_to have_received(:escalate_trigger)
      end
    end

    context "when the PR is ready and GitHub has converted it back to draft" do
      let(:phase) { "ready" }
      let(:pr_data) do
        instance_double(PrDataDouble,
          draft: true,
          head: instance_double(PrHeadDouble, sha: "ready123"),
          updated_at: Time.current)
      end

      it "restarts the draft scan before considering escalation" do
        allow(activity).to receive(:fetch_pr_data).with(client, project, issue).and_return(pr_data)
        allow(activity).to receive(:maybe_restart_draft).with(project, issue, pr_data).and_return(true)
        allow(activity).to receive(:scan_draft_pr).with(project, client, issue, pr_data: pr_data).and_return(:draft_scan)

        result = activity.send(:scan_pr, project, client, issue)

        expect(result).to eq(:draft_scan)
        expect(activity).not_to have_received(:escalate_trigger)
      end
    end

    context "when the PR is ready and stays ready" do
      let(:phase) { "ready" }
      let(:pr_data) do
        instance_double(PrDataDouble,
          draft: false,
          head: instance_double(PrHeadDouble, sha: "ready123"),
          updated_at: Time.current,
          :[] => true)
      end

      it "reuses the cached progress state instead of refetching the head commit timestamp" do
        allow(activity).to receive(:fetch_pr_data).with(client, project, issue).and_return(pr_data)
        allow(activity).to receive(:maybe_restart_draft).with(project, issue, pr_data).and_return(false)
        allow(activity).to receive(:fetch_check_runs).with(client, project, pr_data).and_return([])
        allow(activity).to receive(:bot_user?).with(issue.github_creator_login).and_return(true)
        allow(activity).to receive(:scan_bot_authored_ready_pr).with(
          project,
          client,
          issue,
          pr_data: pr_data,
          checks: [],
          mergeable: true,
          progress_state: progress_state
        ).and_return(:ready_scan)

        result = activity.send(:scan_pr, project, client, issue)

        expect(result).to eq(:ready_scan)
        expect(activity).to have_received(:pr_progress_state).with(project, issue).once
        expect(activity).to have_received(:pr_head_commit_timestamp).with(client, project, issue, pr_data).once
      end
    end

    context "when the PR is ready and live PR data cannot be fetched" do
      let(:phase) { "ready" }

      it "skips instead of escalating on stale state" do
        allow(activity).to receive(:fetch_pr_data).with(client, project, issue).and_return(nil)
        allow(activity).to receive(:maybe_restart_draft).with(project, issue, nil).and_return(false)

        result = activity.send(:scan_pr, project, client, issue)

        expect(result).to eq(:skipped)
        expect(activity).not_to have_received(:escalate_trigger)
      end
    end

    context "when the PR is escalated and the escalation was dismissed" do
      let(:phase) { "escalated" }
      let(:pr_data) do
        instance_double(PrDataDouble,
          draft: false,
          head: instance_double(PrHeadDouble, sha: "escalated123"),
          updated_at: Time.current)
      end

      it "dismisses before any retry-limit escalation can fire" do
        allow(activity).to receive(:fetch_pr_data).with(client, project, issue).and_return(pr_data)
        allow(activity).to receive(:escalation_dismissed?).with(issue).and_return(true)
        allow(activity).to receive(:dismiss_escalation_trigger).with(issue, draft: false).and_return(:dismissed)

        result = activity.send(:scan_pr, project, client, issue)

        expect(result).to eq(:dismissed)
        expect(activity).not_to have_received(:escalate_trigger)
      end

      it "dismisses before the operational failure breaker can re-escalate" do
        allow(activity).to receive(:fetch_pr_data).with(client, project, issue).and_return(pr_data)
        allow(activity).to receive(:escalation_dismissed?).with(issue).and_return(true)
        allow(activity).to receive(:operational_failure_breaker?).with(project, issue, progress_state).and_return(true)
        allow(activity).to receive(:dismiss_escalation_trigger).with(issue, draft: false).and_return(:dismissed)

        result = activity.send(:scan_pr, project, client, issue)

        expect(result).to eq(:dismissed)
        expect(activity).not_to have_received(:escalate_trigger)
      end
    end
  end

  describe "#failure_streak_limit_reached?", :no_db do
    before do
      stub_const("FailureStreakProjectStub", Class.new)
      stub_const("FailureStreakIssueStub", Class.new)
      stub_const("FailureStreakProgressStateStub", Class.new do
        def escalation_worthy?(limit:); end
        def latest_unsuccessful_review?; end
      end)
    end

    let(:activity) { described_class.new }
    let(:project) { instance_double(FailureStreakProjectStub, max_draft_review_rounds: 3) }
    let(:issue) { instance_double(FailureStreakIssueStub, pr_review_phase: "draft") }
    let(:progress_state) do
      instance_double(
        FailureStreakProgressStateStub,
        escalation_worthy?: true,
        latest_unsuccessful_review?: true
      )
    end

    it "suppresses the unified streak gate when a retryable review failure can still be retried" do
      allow(activity).to receive(:review_goal_retry_needed?).with(project, issue, progress_state:).and_return(true)
      allow(activity).to receive(:review_goal_retry_limit_requires_escalation?).with(project, issue, progress_state:).and_return(false)

      expect(activity.send(:failure_streak_limit_reached?, project, issue, progress_state)).to be(false)
    end

    it "keeps the unified streak gate active once the review retry path itself requires escalation" do
      allow(activity).to receive(:review_goal_retry_needed?).with(project, issue, progress_state:).and_return(true)
      allow(activity).to receive(:review_goal_retry_limit_requires_escalation?).with(project, issue, progress_state:).and_return(true)

      expect(activity.send(:failure_streak_limit_reached?, project, issue, progress_state)).to be(true)
    end
  end

  describe "#review_goal_consecutive_failure_count", :no_db do
    before do
      stub_const("RetryLimitProjectStub", Class.new)
      stub_const("RetryLimitIssueStub", Class.new)
      stub_const("RetryLimitProgressStateStub", Class.new)
    end

    let(:activity) { described_class.new }
    let(:project) { instance_double(RetryLimitProjectStub) }
    let(:issue) { instance_double(RetryLimitIssueStub) }
    let(:progress_state) { instance_double(RetryLimitProgressStateStub, last_meaningful_progress_at: progress_at) }
    let(:progress_at) { nil }
    let(:scope) { fake_scope(batches) }

    let(:run_class) do
      Struct.new(:status, :review_posted_at, :created_at, :updated_at, :completed_at, keyword_init: true)
    end

    let(:scope_class) do
      Class.new do
        def initialize(batches)
          @batches = batches
          @offset_value = 0
        end

        def finished
          self
        end

        def order(*)
          self
        end

        def limit(value)
          @limit_value = value
          self
        end

        def offset(value)
          @offset_value = value
          self
        end

        def to_a
          @batches.fetch(@offset_value, [])
        end
      end
    end

    def build_run(status:, at:, review_posted_at: nil)
      run_class.new(
        status: status,
        review_posted_at: review_posted_at,
        created_at: at,
        updated_at: at,
        completed_at: at
      )
    end

    def fake_scope(batches)
      scope_class.new(batches)
    end

    it "drops stale review failures once unified progress advances past them" do
      progress_at = Time.zone.parse("2026-05-15 12:00:00")
      older_failure = build_run(status: "failed", at: progress_at - 30.minutes)

      count = activity.send(
        :consecutive_retryable_review_failures,
        fake_scope(0 => [ older_failure ]),
        progress_state: instance_double(RetryLimitProgressStateStub, last_meaningful_progress_at: progress_at)
      )

      expect(count).to eq(0)
    end

    it "still counts retryable failures when progress has not advanced past them" do
      failure_time = Time.zone.parse("2026-05-15 12:00:00")
      recent_failure = build_run(status: "failed", at: failure_time)

      count = activity.send(
        :consecutive_retryable_review_failures,
        fake_scope(0 => [ recent_failure ]),
        progress_state: instance_double(RetryLimitProgressStateStub, last_meaningful_progress_at: failure_time - 5.minutes)
      )

      expect(count).to eq(1)
    end
  end

  describe "#pr_progress_state", :no_db do
    before do
      stub_const("RetryLimitCacheIssueStub", Class.new)
    end

    let(:activity) { described_class.new }
    let(:project) { Object.new }
    let(:issue) { instance_double(RetryLimitCacheIssueStub, id: 123) }
    let(:stale_state) { instance_double(PullRequests::ProgressState::Result) }
    let(:head_aware_state) { instance_double(PullRequests::ProgressState::Result) }
    let(:fetched_at) { Time.zone.parse("2026-05-15 12:00:00") }

    def cached_progress_state(current_head_updated_at:)
      activity.send(
        :pr_progress_state,
        project,
        issue,
        current_head_sha: "abc123",
        current_head_updated_at:
      )
    end

    it "promotes the head-aware state into the default cache entry" do
      allow(PullRequests::ProgressState).to receive(:call)
        .with(project:, issue:, current_head_sha: nil, current_head_updated_at: nil)
        .and_return(stale_state)
      allow(PullRequests::ProgressState).to receive(:call)
        .with(project:, issue:, current_head_sha: "abc123", current_head_updated_at: kind_of(Time))
        .and_return(head_aware_state)

      expect(activity.send(:pr_progress_state, project, issue)).to eq(stale_state)

      fetched_at = Time.zone.parse("2026-05-15 12:00:00")
      expect(
        activity.send(
          :pr_progress_state,
          project,
          issue,
          current_head_sha: "abc123",
          current_head_updated_at: fetched_at
        )
      ).to eq(head_aware_state)

      expect(activity.send(:pr_progress_state, project, issue)).to eq(head_aware_state)
    end

    it "does not reuse a same-sha cache entry computed before head commit time was known" do
      allow(PullRequests::ProgressState).to receive(:call)
        .with(project:, issue:, current_head_sha: "abc123", current_head_updated_at: nil)
        .and_return(stale_state)
      allow(PullRequests::ProgressState).to receive(:call)
        .with(project:, issue:, current_head_sha: "abc123", current_head_updated_at: fetched_at)
        .and_return(head_aware_state)

      expect(cached_progress_state(current_head_updated_at: nil)).to eq(stale_state)
      expect(cached_progress_state(current_head_updated_at: fetched_at)).to eq(head_aware_state)
    end

    it "does not promote a same-sha cache entry into the default slot before head commit time is known" do
      allow(PullRequests::ProgressState).to receive(:call)
        .with(project:, issue:, current_head_sha: nil, current_head_updated_at: nil)
        .and_return(stale_state)
      allow(PullRequests::ProgressState).to receive(:call)
        .with(project:, issue:, current_head_sha: "abc123", current_head_updated_at: nil)
        .and_return(head_aware_state)

      expect(activity.send(:pr_progress_state, project, issue)).to eq(stale_state)
      expect(cached_progress_state(current_head_updated_at: nil)).to eq(head_aware_state)
      expect(activity.send(:pr_progress_state, project, issue)).to eq(stale_state)
    end

    it "clears the issue-level progress cache when the activity invalidates its cache" do
      allow(issue).to receive(:invalidate_pr_progress_state_cache!)

      activity.send(:invalidate_pr_progress_state, issue)

      expect(issue).to have_received(:invalidate_pr_progress_state_cache!)
    end
  end

  describe "#execute", :no_db do
    before do
      stub_const("Project", Class.new do
        def self.find_by(id:); end
      end)
      stub_const("ExecuteCacheProjectStub", Class.new)
      stub_const("ExecuteCacheIssueStub", Class.new)
      stub_const("ExecuteCacheAccountStub", Class.new)
      stub_const("ExecuteCacheTenantSettingStub", Class.new)
      stub_const("ExecuteCacheGithubTokenStub", Class.new)
      stub_const("ExecuteCacheGithubClientStub", Class.new)
      stub_const("ExecuteCacheProgressStateStub", Class.new)
    end

    let(:activity) { described_class.new }
    let(:project) do
      instance_double(
        ExecuteCacheProjectStub,
        id: 7,
        auto_scan_prs: true,
        account: account,
        github_token: github_token
      )
    end
    let(:account) { instance_double(ExecuteCacheAccountStub, id: 11, tenant_setting: tenant_setting) }
    let(:tenant_setting) { instance_double(ExecuteCacheTenantSettingStub, auto_continue?: true) }
    let(:github_token) { instance_double(ExecuteCacheGithubTokenStub, client: github_client) }
    let(:github_client) { instance_double(ExecuteCacheGithubClientStub) }
    let(:issue) do
      instance_double(
        ExecuteCacheIssueStub,
        id: 123,
        github_number: 42,
        project: project
      )
    end
    let(:first_progress_state) do
      instance_double(
        ExecuteCacheProgressStateStub,
        consecutive_unsuccessful_automatic_runs: 1,
        consecutive_operational_failures: 0,
        last_meaningful_progress_at: nil,
        latest_automatic_run_at: nil,
        latest_unsuccessful_run_at: nil,
        latest_unsuccessful_run_goal: nil,
        latest_unsuccessful_run_status: nil
      )
    end
    let(:second_progress_state) do
      instance_double(
        ExecuteCacheProgressStateStub,
        consecutive_unsuccessful_automatic_runs: 3,
        consecutive_operational_failures: 2,
        last_meaningful_progress_at: nil,
        latest_automatic_run_at: nil,
        latest_unsuccessful_run_at: nil,
        latest_unsuccessful_run_goal: "review",
        latest_unsuccessful_run_status: "failed"
      )
    end

    def serialized_state(issue_id:, streak:, operational_streak:, goal:, status:)
      {
        issue_id: issue_id,
        consecutive_unsuccessful_automatic_runs: streak,
        consecutive_operational_failures: operational_streak,
        last_meaningful_progress_at: nil,
        latest_automatic_run_at: nil,
        latest_unsuccessful_run_at: nil,
        latest_unsuccessful_run_goal: goal,
        latest_unsuccessful_run_status: status
      }
    end

    it "resets the per-execution progress cache so reused activity instances do not leak stale state" do
      allow(Project).to receive(:find_by).with(id: project.id).and_return(project)
      allow(activity).to receive(:find_paid_prs).with(project).and_return([ issue ])
      allow(activity).to receive(:skip_unchanged_pr?).with(project, issue).and_return(false)
      allow(activity).to receive(:scan_pr).with(project, github_client, issue).and_return(nil)
      allow(issue).to receive(:update_column).with(:last_pr_scan_at, kind_of(Time))
      allow(activity).to receive(:pending_review_state).with(issue, nil).and_return(nil)
      allow(FeatureFlags).to receive(:explicit_pr_automation_decisions?).with(project:).and_return(false)
      allow(activity).to receive(:logger).and_return(instance_double(Logger, info: true, warn: true))
      allow(PullRequests::ProgressState).to receive(:call)
        .with(project:, issue:, current_head_sha: nil, current_head_updated_at: nil)
        .and_return(first_progress_state, second_progress_state)

      first_result = activity.execute(project_id: project.id)
      second_result = activity.execute(project_id: project.id)

      expect(first_result[:pr_progress_states]).to eq([
        serialized_state(issue_id: 123, streak: 1, operational_streak: 0, goal: nil, status: nil)
      ])
      expect(second_result[:pr_progress_states]).to eq([
        serialized_state(issue_id: 123, streak: 3, operational_streak: 2, goal: "review", status: "failed")
      ])
      expect(PullRequests::ProgressState).to have_received(:call).twice
    end
  end

  describe "#maybe_advance_to_ready", :no_db do
    before do
      stub_const("AdvanceReadyProjectStub", Class.new)
      stub_const("AdvanceReadyIssueStub", Class.new)
      stub_const("AdvanceReadyPrDataStub", Class.new)
    end

    let(:activity) { described_class.new }
    let(:project) { instance_double(AdvanceReadyProjectStub, id: 123) }
    let(:issue) do
      instance_double(
        AdvanceReadyIssueStub,
        draft_phase?: true,
        pr_review_phase: "draft",
        github_number: 42
      )
    end
    let(:pr_data) { instance_double(AdvanceReadyPrDataStub, draft: false) }

    it "invalidates cached PR progress after advancing the local phase to ready" do
      allow(issue).to receive(:update!).with(pr_review_phase: "ready")
      allow(activity).to receive(:invalidate_pr_progress_state).with(issue)
      allow(activity).to receive(:logger).and_return(instance_double(Logger, info: true))

      result = activity.send(:maybe_advance_to_ready, project, issue, pr_data)

      expect(result).to be(true)
      expect(activity).to have_received(:invalidate_pr_progress_state).with(issue)
    end
  end

  describe "#followup_limit_reached?", :no_db do
    before do
      stub_const("FollowupLimitProjectStub", Class.new)
      stub_const("FollowupLimitIssueStub", Class.new)
      stub_const("FollowupLimitProgressStateStub", Class.new)
    end

    let(:activity) { described_class.new }
    let(:project) { instance_double(FollowupLimitProjectStub) }
    let(:issue) { instance_double(FollowupLimitIssueStub, pr_review_phase: "ready", draft_phase?: false) }

    it "suppresses the ready-phase follow-up gate for review failures that should not escalate" do
      progress_state = instance_double(
        FollowupLimitProgressStateStub,
        latest_unsuccessful_review?: true
      )
      allow(activity).to receive(:review_goal_retry_limit_requires_escalation?)
        .with(project, issue, progress_state:)
        .and_return(false)

      expect(activity.send(:followup_limit_reached?, project, issue, progress_state)).to be(false)
    end

    it "keeps the ready-phase follow-up gate for non-review failure streaks" do
      progress_state = instance_double(
        FollowupLimitProgressStateStub,
        latest_unsuccessful_review?: false,
        escalation_worthy?: true
      )
      allow(project).to receive(:max_pr_followup_runs).and_return(3)

      expect(activity.send(:followup_limit_reached?, project, issue, progress_state)).to be(true)
    end
  end

  describe "#build_lifecycle_signals", :no_db do
    before do
      stub_const("LifecycleSignalsProjectStub", Class.new)
      stub_const("LifecycleSignalsIssueStub", Class.new)
      stub_const("LifecycleSignalsProgressStateStub", Class.new)
    end

    let(:activity) { described_class.new }
    let(:project) { instance_double(LifecycleSignalsProjectStub, owner_reviewer_login: "alice") }
    let(:issue) do
      instance_double(
        LifecycleSignalsIssueStub,
        id: 123,
        github_number: 42,
        pr_review_phase: "ready",
        draft_review_count: 0,
        review_goal_retry_count: 1,
        pr_followup_count: 0
      )
    end
    let(:progress_state) do
      instance_double(
        LifecycleSignalsProgressStateStub,
        consecutive_unsuccessful_automatic_runs: 3,
        consecutive_operational_failures: 0,
        last_meaningful_progress_at: nil
      )
    end

    it "reports the unified failure streak even when the ready follow-up gate is suppressed" do
      allow(activity).to receive(:pr_progress_state).with(project, issue).and_return(progress_state)
      allow(activity).to receive(:operational_failure_breaker?).with(project, issue, progress_state).and_return(false)
      allow(activity).to receive(:failure_streak_limit_reached?).with(project, issue, progress_state).and_return(true)
      allow(activity).to receive(:review_goal_retry_limit_requires_escalation?)
        .with(project, issue, progress_state:)
        .and_return(false)
      allow(activity).to receive(:failure_streak_reason).with(project, issue, progress_state)
        .and_return("Automatic PR failure streak reached")
      allow(activity).to receive(:active_run_exists?).with(project, issue).and_return(false)
      allow(activity).to receive(:escalation_dismissed?).with(issue).and_return(false)

      signals = activity.send(:build_lifecycle_signals, project, issue)

      expect(signals).to include(
        failure_streak_limit_reached: true,
        escalation_reason: "Automatic PR failure streak reached",
        consecutive_unsuccessful_automatic_runs: 3,
        review_goal_retry_count: 1
      )
    end
  end
end
