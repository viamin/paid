# frozen_string_literal: true

require "rails_helper"

# @spec EAGER-QUEUE-DIAG-001 EAGER-QUEUE-DIAG-002
RSpec.describe Dashboard::QueueDiagnosis do
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account) }
  let(:project) { create(:project, account: account, created_by: user, auto_pick_enabled: true) }

  it "identifies eligible work that has not been seeded" do
    create(:issue, project: project, github_state: "open", paid_state: "new")

    diagnosis = described_class.call(user: user, rendered_runs: [])

    expect(diagnosis.state).to eq(:runnable_unseeded)
    expect(diagnosis.eligible_count).to eq(1)
    expect(diagnosis.queued_count).to eq(0)
    expect(diagnosis.next_action).to eq(:refresh)
  end

  it "does not call an empty queue a failure when all work is active" do
    create(:agent_run, :running, project: project)

    diagnosis = described_class.call(user: user, rendered_runs: [])

    expect(diagnosis.state).to eq(:active_work)
    expect(diagnosis.active_count).to eq(1)
  end

  it "reports held open work separately from runnable candidates" do
    blocker = create(:issue, project: project, github_state: "open", paid_state: "new", labels: [ "planning" ])
    create(:issue, project: project, github_state: "open", paid_state: "new") do |issue|
      create(:issue_dependency, issue: issue, depends_on_issue: blocker)
    end

    diagnosis = described_class.call(user: user, rendered_runs: [])

    expect(diagnosis.state).to eq(:held)
    expect(diagnosis.held_count).to be_positive
  end

  it "shows a disconnected rendered preview when the backend still has queued work" do
    create(:agent_run, :queued, project: project)

    diagnosis = described_class.call(user: user, rendered_runs: [])

    expect(diagnosis.state).to eq(:refresh_mismatch)
    expect(diagnosis.queued_count).to eq(1)
  end

  it "returns unknown rather than treating an unavailable query as no work" do
    allow(AgentRun).to receive(:schedulable_queued_with_priority).and_raise(ActiveRecord::ConnectionNotEstablished)

    diagnosis = described_class.call(user: user, rendered_runs: [])

    expect(diagnosis.state).to eq(:unknown)
    expect(diagnosis.next_action).to eq(:refresh)
  end
end
