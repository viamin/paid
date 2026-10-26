# frozen_string_literal: true

require "rails_helper"

RSpec.describe Dashboard::QueueDiagnosis do
  let(:user) { create(:user) }
  let(:account) { user.account }
  let!(:project) { create(:project, account:, created_by: user, auto_pick_enabled: true, active: true) }

  # @spec EAGER-QUEUE-017 EAGER-QUEUE-018
  it "identifies eligible work that has not been seeded without mutating it" do
    issue = create(:issue, project:, github_state: "open", paid_state: "new")

    diagnosis = described_class.call(user:)

    expect(diagnosis.state).to eq(:runnable_unseeded)
    expect(diagnosis.eligible_count).to eq(1)
    expect(diagnosis.queued_count).to eq(0)
    expect(diagnosis.entries.map(&:issue)).to contain_exactly(issue)
    expect(diagnosis.entries.sole.next_action).to eq(:wait_for_eligibility_sweep)
    expect(AgentRun.where(issue:)).to be_empty
  end

  # @spec EAGER-QUEUE-017
  it "does not call an empty queue stalled while all work is active" do
    issue = create(:issue, project:, github_state: "open", paid_state: "new")
    create(:agent_run, :running, :automatic, project:, issue:)

    diagnosis = described_class.call(user:)

    expect(diagnosis.state).to eq(:active_work)
    expect(diagnosis.active_count).to eq(1)
    expect(diagnosis.eligible_count).to eq(0)
  end

  # @spec EAGER-QUEUE-017 EAGER-QUEUE-018
  it "reports a dependency hold with blocker provenance instead of clearing it" do
    blocker = create(:issue, project:, github_state: "open", paid_state: "new", labels: [ "tracking" ])
    dependent = create(:issue, project:, github_state: "open", paid_state: "new")
    create(:issue_dependency, issue: dependent, depends_on_issue: blocker)

    diagnosis = described_class.call(user:)

    expect(diagnosis.state).to eq(:held)
    entry = diagnosis.entries.find { |candidate| candidate.issue == dependent }
    expect(entry.blockers).to include("dependency:#{blocker.id}")
    expect(entry.next_action).to eq(:resolve_dependency)
  end

  # @spec EAGER-QUEUE-017
  it "reports a deliberate project pause rather than an empty healthy backlog" do
    project.update!(scheduler_paused_at: Time.current)

    diagnosis = described_class.call(user:)

    expect(diagnosis.state).to eq(:policy_paused)
    expect(diagnosis.next_action).to eq(:resume_project)
  end

  # @spec EAGER-QUEUE-017
  it "does not include another tenant's candidates or runs" do
    other_user = create(:user)
    other_project = create(:project, account: other_user.account, created_by: other_user, auto_pick_enabled: true, active: true)
    create(:issue, project: other_project, github_state: "open", paid_state: "new")

    diagnosis = described_class.call(user:)

    expect(diagnosis.eligible_count).to eq(0)
    expect(diagnosis.entries).to be_empty
  end
end
