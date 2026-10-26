# frozen_string_literal: true

require "rails_helper"

RSpec.describe Dashboard::QueueDiagnosis do
  let(:user) { create(:user) }
  let(:project) { create(:project, account: user.account, created_by: user, auto_pick_enabled: true) }

  it "reports eligible work with no queued run as an unseeded handoff" do # @spec EAGER-QUEUE-017
    create(:issue, project: project, github_state: "open", paid_state: "new")

    diagnosis = described_class.call(user: user)

    expect(diagnosis.state).to eq(:eligible_unseeded)
    expect(diagnosis.eligible_count).to eq(1)
    expect(diagnosis.queued_count).to eq(0)
  end

  it "does not call an empty queue stalled while work is actively running" do # @spec EAGER-QUEUE-017
    issue = create(:issue, project: project, github_state: "open", paid_state: "in_progress")
    create(:agent_run, :running, project: project, issue: issue)

    diagnosis = described_class.call(user: user)

    expect(diagnosis.state).to eq(:healthy_active_work)
    expect(diagnosis.active_count).to eq(1)
  end

  it "keeps persisted backend queue contents distinct from an empty rendered preview" do # @spec EAGER-QUEUE-017
    create(:agent_run, :queued, project: project)

    diagnosis = described_class.call(user: user)

    expect(diagnosis.state).to eq(:runnable_queued)
    expect(diagnosis.queued_count).to eq(1)
  end

  it "reports a dependency hold without claiming it is an empty backlog" do # @spec EAGER-QUEUE-017
    blocker = create(:issue, project: project, github_state: "open", paid_state: "new", labels: [ "planning" ])
    create(:issue, project: project, github_state: "open", paid_state: "new") do |dependent|
      create(:issue_dependency, issue: dependent, depends_on_issue: blocker)
    end

    diagnosis = described_class.call(user: user)

    expect(diagnosis.state).to eq(:dependency_or_decision_hold)
    expect(diagnosis.blocked_count).to eq(1)
  end

  it "reports unavailable diagnosis rather than treating a failed query as no work" do # @spec EAGER-QUEUE-017
    allow(Dashboard::EligibilityBreakdown).to receive(:call).and_raise(ActiveRecord::StatementInvalid, "unavailable")

    diagnosis = described_class.call(user: user)

    expect(diagnosis.state).to eq(:unknown)
    expect(diagnosis.recovery_action).to eq("Refresh diagnosis")
  end
end
