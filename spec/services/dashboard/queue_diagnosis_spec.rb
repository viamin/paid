# frozen_string_literal: true

require "rails_helper"

RSpec.describe Dashboard::QueueDiagnosis do
  # @spec DASHBOARD-QUEUE-DIAGNOSIS-001
  it "identifies eligible work that has not been seeded" do
    user = create(:user)
    project = create(:project, account: user.account, created_by: user, auto_pick_enabled: true)
    create(:issue, project:, github_state: "open", paid_state: "new")

    diagnosis = described_class.call(user: user)

    expect(diagnosis.state).to eq(:runnable_unseeded)
    expect(diagnosis.eligible_count).to eq(1)
    expect(diagnosis.queued_count).to eq(0)
    expect(diagnosis.active_count).to eq(0)
  end

  # @spec DASHBOARD-QUEUE-DIAGNOSIS-001
  it "does not call an empty queue a failure while work is active" do
    user = create(:user)
    project = create(:project, account: user.account, created_by: user, auto_pick_enabled: true)
    issue = create(:issue, project:, github_state: "open", paid_state: "new")
    create(:agent_run, :running, project:, issue: issue)

    diagnosis = described_class.call(user: user)

    expect(diagnosis.state).to eq(:active_work)
    expect(diagnosis.active_count).to eq(1)
  end
end
