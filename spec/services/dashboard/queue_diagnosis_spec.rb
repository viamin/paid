# frozen_string_literal: true

require "rails_helper"

RSpec.describe Dashboard::QueueDiagnosis do
  let(:account) { create(:account) }
  let(:user) { create(:user, account:) }
  let(:project) { create(:project, account:, created_by: user, auto_pick_enabled: true, active: true) }

  # @spec QUEUE-DIAGNOSIS-001
  it "reports runnable work that has not been seeded" do
    create(:issue, project:, github_state: "open")

    diagnosis = described_class.call(user:, rendered_queue_count: 0)

    expect(diagnosis.state).to eq(:runnable_unseeded)
    expect(diagnosis.eligible_count).to eq(1)
    expect(diagnosis.queued_count).to eq(0)
  end

  # @spec QUEUE-DIAGNOSIS-001
  it "does not call active work a stalled queue" do
    issue = create(:issue, project:, github_state: "open")
    create(:agent_run, :running, project:, issue:)

    diagnosis = described_class.call(user:, rendered_queue_count: 0)

    expect(diagnosis.state).to eq(:healthy_active_work)
    expect(diagnosis.active_count).to eq(1)
  end

  # @spec QUEUE-DIAGNOSIS-002
  it "detects a nonempty backend queue missing from the rendered queue" do
    create(:agent_run, :queued, :manual, project:)

    diagnosis = described_class.call(user:, rendered_queue_count: 0)

    expect(diagnosis.state).to eq(:stale_dashboard)
    expect(diagnosis.queued_count).to eq(1)
  end

  # @spec QUEUE-DIAGNOSIS-003
  it "keeps multiple mechanical blockers on one inspectable issue" do
    blocker = create(:issue, project:, github_state: "open", labels: [ "tracking" ])
    issue = create(:issue, project:, github_state: "open", labels: [ "tracking" ])
    create(:issue_dependency, issue:, depends_on_issue: blocker)

    diagnosis = described_class.call(user:, rendered_queue_count: 0)

    record = diagnosis.blockers.find { |entry| entry.issue == issue }
    expect(record.reasons).to include(:skip_label, :dependency)
    expect(diagnosis.state).to eq(:genuine_holds)
  end

  # @spec QUEUE-DIAGNOSIS-001
  it "reports a deliberate quality pause without calling it an empty backlog" do
    project.update!(quality_paused_at: Time.current)

    diagnosis = described_class.call(user:, rendered_queue_count: 0)

    expect(diagnosis.state).to eq(:resource_policy_paused)
  end

  # @spec QUEUE-DIAGNOSIS-002
  it "reports an unavailable eligibility query as unknown coverage" do
    allow(Dashboard::EligibilityBreakdown).to receive(:call).and_raise(ActiveRecord::ConnectionNotEstablished)

    diagnosis = described_class.call(user:, rendered_queue_count: 0)

    expect(diagnosis.state).to eq(:unknown)
    expect(diagnosis.refresh_needed?).to be(true)
  end

  # @spec QUEUE-DIAGNOSIS-003
  it "does not count another tenant's queue or candidates" do
    other_account = create(:account)
    other_user = create(:user, account: other_account)
    other_project = create(:project, account: other_account, created_by: other_user, auto_pick_enabled: true, active: true)
    create(:issue, project: other_project, github_state: "open")
    create(:agent_run, :queued, :manual, project: other_project)
    create(:issue, project:, github_state: "open")

    diagnosis = described_class.call(user:, rendered_queue_count: 0)

    expect(diagnosis.state).to eq(:runnable_unseeded)
    expect(diagnosis.queued_count).to eq(0)
    expect(diagnosis.eligible_count).to eq(1)
  end

  # @spec QUEUE-DIAGNOSIS-004
  it "does not enqueue or recover work while diagnosing" do
    create(:issue, project:, github_state: "open")
    allow(Issues::BulkEnqueueEligible).to receive(:call)

    described_class.call(user:, rendered_queue_count: 0)

    expect(Issues::BulkEnqueueEligible).not_to have_received(:call)
  end
end
