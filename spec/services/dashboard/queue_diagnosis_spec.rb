# frozen_string_literal: true

require "rails_helper"

RSpec.describe Dashboard::QueueDiagnosis do
  around do |example|
    original_store = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    example.run
  ensure
    Rails.cache = original_store
  end

  let(:user) { create(:user) }
  let(:account) { user.account }
  let(:project) { create(:project, account:, created_by: user, auto_pick_enabled: true, active: true) }

  # @spec QUEUE-DIAGNOSIS-001
  it "reports runnable work that has not been seeded" do
    issue = create(:issue, project:, github_state: "open", paid_state: "new")

    report = described_class.call(user:)

    expect(report.state).to eq(:runnable_unseeded)
    expect(report.eligible_count).to eq(1)
    expect(report.queued_count).to eq(0)
    expect(report.next_action).to include("eligibility sweep")
    expect(report.issues.map(&:id)).to eq([ issue.id ])
  end

  # @spec QUEUE-DIAGNOSIS-001
  it "does not call an empty queue a failure while work is active" do
    issue = create(:issue, project:, github_state: "open", paid_state: "in_progress")
    create(:agent_run, :running, project:, issue:)

    report = described_class.call(user:)

    expect(report.state).to eq(:healthy_active_work)
    expect(report.active_count).to eq(1)
  end

  # @spec QUEUE-DIAGNOSIS-002
  it "shows every local dependency blocker for a held issue" do
    first = create(:issue, project:, github_state: "open", paid_state: "new", labels: [ "tracking" ])
    second = create(:issue, project:, github_state: "open", paid_state: "new", labels: [ "tracking" ])
    dependent = create(:issue, project:, github_state: "open", paid_state: "new")
    create(:issue_dependency, issue: dependent, depends_on_issue: first)
    create(:issue_dependency, issue: dependent, depends_on_issue: second)

    report = described_class.call(user:)

    expect(report.state).to eq(:dependency_or_decision_hold)
    blocker = report.blockers.find { |entry| entry.issue == dependent }
    expect(blocker.blocking_issues).to contain_exactly(first, second)
  end

  # @spec QUEUE-DIAGNOSIS-001
  it "reports an explicit scheduler pause without attempting recovery" do
    project.update!(scheduler_paused_at: Time.current)

    report = described_class.call(user:)

    expect(report.state).to eq(:resource_or_policy_pause)
    expect(report.next_action).to include("Resume")
  end

  # @spec QUEUE-DIAGNOSIS-001
  it "distinguishes queued backend work that is not schedulable for the preview" do
    create(:agent_run, :queued, :manual, project: project)
    project.update!(scheduler_paused_at: Time.current)

    report = described_class.call(user:)

    expect(report.state).to eq(:backend_queued_not_rendered)
    expect(report.queued_count).to eq(1)
    expect(report.schedulable_queued_count).to eq(0)
  end

  # @spec QUEUE-DIAGNOSIS-001
  it "refreshes cached diagnosis after the dashboard list version changes" do
    first = described_class.call(user:)
    create(:agent_run, :queued, :manual, project: project)

    cached = described_class.call(user:)
    Dashboard::CacheVersion.bump(account, scope: Dashboard::CacheVersion::LISTS_SCOPE)
    refreshed = described_class.call(user:)

    expect(first.state).to eq(:no_waiting_work)
    expect(cached.state).to eq(:no_waiting_work)
    expect(refreshed.state).to eq(:queued)
  end

  # @spec QUEUE-DIAGNOSIS-001
  it "does not include queued work owned by another account" do
    other_project = create(:project, auto_pick_enabled: true, active: true)
    create(:agent_run, :queued, :manual, project: other_project)

    report = described_class.call(user:)

    expect(report.queued_count).to eq(0)
  end

  # @spec QUEUE-DIAGNOSIS-003
  it "reports unknown coverage when canonical eligibility data is unavailable" do
    allow(Dashboard::EligibilityBreakdown).to receive(:call).and_raise(ActiveRecord::StatementInvalid, "unavailable")

    report = described_class.call(user:)

    expect(report.state).to eq(:unknown)
    expect(report.next_action).to include("Refresh")
  end
end
