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
      stub_const("ProgressStateDouble", Class.new)
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
  end
end
