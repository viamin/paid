# frozen_string_literal: true

require "rails_helper"

RSpec.describe PullRequests::ProgressState, :no_db do
  before do
    stub_const("ProgressStateProjectStub", Class.new)
    stub_const("ProgressStateIssueStub", Struct.new(
      :github_number,
      :review_goal_retry_reset_at,
      :operational_failure_reset_at,
      keyword_init: true
    ))
    stub_const("ProgressStateFakeRunScope", Class.new do
      attr_reader :offsets_fetched, :order_args

      def initialize(batches)
        @batches = batches
        @offsets_fetched = []
        @offset_value = 0
      end

      def where(*)
        self
      end

      def finished
        self
      end

      def not(*)
        self
      end

      def order(*args)
        @order_args = args
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
        offsets_fetched << @offset_value
        @batches.fetch(@offset_value, [])
      end
    end)
  end

  let(:run_class) do
    Struct.new(
      :goal,
      :status,
      :trigger_type,
      :created_at,
      :updated_at,
      :completed_at,
      :review_posted_at,
      :operational_failure_flag,
      keyword_init: true
    ) do
      def finished?
        true
      end

      def operational_failure?
        operational_failure_flag
      end
    end
  end

  let(:project) { instance_double(ProgressStateProjectStub) }
  let(:issue) { issue_double }

  def build_run(goal:, status:, at:, review_posted_at: nil, operational_failure: false)
    run_class.new(
      goal: goal,
      status: status,
      trigger_type: "automatic",
      created_at: at,
      updated_at: at,
      completed_at: at,
      review_posted_at: review_posted_at,
      operational_failure_flag: operational_failure
    )
  end

  def issue_double(review_goal_retry_reset_at: nil, operational_failure_reset_at: nil)
    instance_double(
      ProgressStateIssueStub,
      github_number: 42,
      review_goal_retry_reset_at: review_goal_retry_reset_at,
      operational_failure_reset_at: operational_failure_reset_at
    )
  end

  def fake_run_scope(batches)
    ProgressStateFakeRunScope.new(batches)
  end

  def batched_history(now)
    {
      0 => [
        build_run(goal: "review", status: "failed", at: now),
        build_run(goal: "create_pr", status: "failed", at: now - 5.minutes)
      ],
      2 => [
        build_run(goal: "create_pr", status: "completed", at: now - 10.minutes),
        build_run(goal: "create_pr", status: "failed", at: now - 15.minutes)
      ],
      4 => [
        build_run(goal: "create_pr", status: "failed", at: now - 20.minutes)
      ]
    }
  end

  it "keeps one failure streak across failed draft and ready phase runs" do
    now = Time.zone.parse("2026-05-15 12:00:00")
    runs = [
      build_run(goal: "review", status: "failed", at: now),
      build_run(goal: "create_pr", status: "no_output", at: now - 5.minutes),
      build_run(goal: "create_pr", status: "failed", at: now - 10.minutes)
    ]

    result = described_class.call(project: project, issue: issue, runs: runs)

    expect(result.consecutive_unsuccessful_automatic_runs).to eq(3)
    expect(result.latest_unsuccessful_run_goal).to eq("review")
  end

  it "resets the unified streak after successful create_pr progress" do
    now = Time.zone.parse("2026-05-15 12:00:00")
    runs = [
      build_run(goal: "review", status: "failed", at: now),
      build_run(goal: "create_pr", status: "completed", at: now - 5.minutes),
      build_run(goal: "create_pr", status: "failed", at: now - 10.minutes)
    ]

    result = described_class.call(project: project, issue: issue, runs: runs)

    expect(result.consecutive_unsuccessful_automatic_runs).to eq(1)
    expect(result.last_meaningful_progress_at).to eq(now - 5.minutes)
  end

  it "resets the unified streak after a review is posted" do
    now = Time.zone.parse("2026-05-15 12:00:00")
    runs = [
      build_run(goal: "create_pr", status: "failed", at: now),
      build_run(goal: "review", status: "failed", at: now - 5.minutes, review_posted_at: now - 5.minutes),
      build_run(goal: "create_pr", status: "failed", at: now - 10.minutes)
    ]

    result = described_class.call(project: project, issue: issue, runs: runs)

    expect(result.consecutive_unsuccessful_automatic_runs).to eq(1)
    expect(result.last_meaningful_progress_at).to eq(now - 5.minutes)
  end

  it "resets the streak from explicit human progress markers" do
    now = Time.zone.parse("2026-05-15 12:00:00")
    reset_issue = issue_double(review_goal_retry_reset_at: now - 2.minutes)
    runs = [
      build_run(goal: "review", status: "failed", at: now - 5.minutes),
      build_run(goal: "create_pr", status: "failed", at: now - 10.minutes)
    ]

    result = described_class.call(project: project, issue: reset_issue, runs: runs)

    expect(result.consecutive_unsuccessful_automatic_runs).to eq(0)
    expect(result.last_meaningful_progress_at).to eq(now - 2.minutes)
  end

  it "does not let phase transitions alone change the counting regime" do
    now = Time.zone.parse("2026-05-15 12:00:00")
    runs = [
      build_run(goal: "review", status: "failed", at: now),
      build_run(goal: "create_pr", status: "failed", at: now - 5.minutes)
    ]
    draft_result = described_class.call(project: project, issue: issue_double, runs: runs)
    ready_result = described_class.call(project: project, issue: issue_double, runs: runs)

    expect(draft_result.consecutive_unsuccessful_automatic_runs).to eq(2)
    expect(ready_result.consecutive_unsuccessful_automatic_runs).to eq(2)
  end

  it "tracks consecutive operational failures across create_pr and review runs" do
    now = Time.zone.parse("2026-05-15 12:00:00")
    runs = [
      build_run(goal: "review", status: "failed", at: now, operational_failure: true),
      build_run(goal: "create_pr", status: "timeout", at: now - 5.minutes, operational_failure: true),
      build_run(goal: "create_pr", status: "failed", at: now - 10.minutes, operational_failure: false)
    ]

    result = described_class.call(project: project, issue: issue, runs: runs)

    expect(result.consecutive_operational_failures).to eq(2)
    expect(result.consecutive_unsuccessful_automatic_runs).to eq(3)
  end

  it "loads database-backed history in ordered batches and stops after meaningful progress" do
    stub_const("#{described_class}::RUN_BATCH_SIZE", 2)

    now = Time.zone.parse("2026-05-15 12:00:00")
    scope = fake_run_scope(batched_history(now))
    allow(project).to receive(:agent_runs).and_return(scope)

    result = described_class.call(project: project, issue: issue)

    expect(result.consecutive_unsuccessful_automatic_runs).to eq(2)
    expect(result.last_meaningful_progress_at).to eq(now - 10.minutes)
    expect(scope.offsets_fetched).to eq([ 0, 2 ])
    expect(scope.order_args).to be_present
  end
end
