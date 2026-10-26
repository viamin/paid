# frozen_string_literal: true

require "rails_helper"

RSpec.describe Dashboard::QueueDiagnosis do
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account) }
  let(:project) { create(:project, account: account, created_by: user, auto_pick_enabled: true, active: true) }

  # @spec QUEUE-DIAGNOSIS-001
  it "identifies eligible work that has not been seeded without treating it as an empty backlog" do
    issue = create(:issue, project: project, github_state: "open", paid_state: "new")

    diagnosis = described_class.call(user: user)

    expect(diagnosis.state).to eq(:runnable_unseeded)
    expect(diagnosis.eligible_count).to eq(1)
    expect(diagnosis.queued_count).to eq(0)
    expect(diagnosis.active_count).to eq(0)
    expect(diagnosis.entries.map(&:issue)).to include(issue)
  end

  # @spec QUEUE-DIAGNOSIS-002
  it "recognizes an empty waiting queue as healthy while all eligible work is active" do
    issue = create(:issue, project: project, github_state: "open", paid_state: "new")
    create(:agent_run, :running, :automatic, project: project, issue: issue)

    diagnosis = described_class.call(user: user)

    expect(diagnosis.state).to eq(:healthy_active_work)
    expect(diagnosis.active_count).to eq(1)
  end

  # @spec QUEUE-DIAGNOSIS-003
  it "reports dependency-held work with its blocker instead of calling it an empty queue" do
    blocker = create(:issue, project: project, github_state: "open", paid_state: "new", labels: [ "tracking" ])
    blocked = create(:issue, project: project, github_state: "open", paid_state: "new")
    create(:issue_dependency, issue: blocked, depends_on_issue: blocker)

    diagnosis = described_class.call(user: user)

    expect(diagnosis.state).to eq(:held)
    entry = diagnosis.entries.find { |candidate| candidate.issue == blocked }
    expect(entry.blockers).to include("Dependency ##{blocker.github_number}")
  end

  # @spec QUEUE-DIAGNOSIS-004
  it "returns unknown coverage when the canonical eligibility query fails" do
    allow(Dashboard::EligibilityBreakdown).to receive(:call).and_raise(ActiveRecord::StatementInvalid, "database unavailable")

    diagnosis = described_class.call(user: user)

    expect(diagnosis.state).to eq(:unknown)
    expect(diagnosis.recovery_action).to eq("Refresh diagnosis")
  end

  # @spec QUEUE-DIAGNOSIS-005
  it "does not expose another tenant's work" do
    other_account = create(:account)
    other_user = create(:user, account: other_account)
    other_project = create(:project, account: other_account, created_by: other_user, auto_pick_enabled: true, active: true)
    create(:issue, project: other_project, github_state: "open", paid_state: "new")

    diagnosis = described_class.call(user: user)

    expect(diagnosis.eligible_count).to eq(0)
    expect(diagnosis.entries).to be_empty
  end
end
