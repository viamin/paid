# frozen_string_literal: true

require "rails_helper"

RSpec.describe Dashboard::QueueDiagnosis do
  let(:account) { create(:account) }
  let(:user) { create(:user, account:) }
  let(:project) { create(:project, account:, created_by: user, auto_pick_enabled: true) }

  # @spec EAGER-QUEUE-017
  it "identifies eligible work that has not been seeded without treating it as queued" do
    issue = create(:issue, project:, github_state: "open", paid_state: "new")

    diagnosis = described_class.call(user:)

    expect(diagnosis.state).to eq(:runnable_unseeded)
    expect(diagnosis.eligible_count).to eq(1)
    expect(diagnosis.queued_count).to eq(0)
    expect(diagnosis.active_count).to eq(0)
    expect(diagnosis.unseeded_issues).to eq([ issue ])
  end

  # @spec EAGER-QUEUE-017
  it "reports active work as healthy progress when no eligible issue is waiting" do
    issue = create(:issue, project:, github_state: "open", paid_state: "new")
    create(:agent_run, :running, project:, issue:, trigger_type: "automatic")

    diagnosis = described_class.call(user:)

    expect(diagnosis.state).to eq(:active_work)
    expect(diagnosis.eligible_count).to eq(0)
    expect(diagnosis.active_count).to eq(1)
  end

  # @spec EAGER-QUEUE-017
  it "reports a deliberate policy pause instead of claiming the empty queue is healthy" do
    project.update!(quality_paused_at: Time.current)
    create(:issue, project:, github_state: "open", paid_state: "new")

    diagnosis = described_class.call(user:)

    expect(diagnosis.state).to eq(:paused)
    expect(diagnosis.eligible_count).to eq(0)
  end

  # @spec EAGER-QUEUE-017
  it "distinguishes queued backend work from an empty rendered scheduler preview" do
    project.update!(quality_paused_at: Time.current)
    create(:agent_run, :queued, project:, trigger_type: "automatic")

    diagnosis = described_class.call(user:)

    expect(diagnosis.state).to eq(:backend_nonempty)
    expect(diagnosis.queued_count).to eq(1)
    expect(diagnosis.recovery_action).to include("Refresh")
  end

  # @spec EAGER-QUEUE-017
  it "does not include another tenant's candidates or runs" do
    other_account = create(:account)
    other_user = create(:user, account: other_account)
    other_project = create(:project, account: other_account, created_by: other_user, auto_pick_enabled: true)
    create(:issue, project: other_project, github_state: "open", paid_state: "new")

    diagnosis = described_class.call(user:)

    expect(diagnosis.state).to eq(:healthy)
    expect(diagnosis.eligible_count).to eq(0)
    expect(diagnosis.queued_count).to eq(0)
  end

  # @spec EAGER-QUEUE-017
  it "returns unknown coverage when canonical eligibility cannot be read" do
    project
    allow(Automation::Strategies::AutoPick::DefaultCandidateSource)
      .to receive(:eligible_scope).and_raise(ActiveRecord::ConnectionTimeoutError)

    diagnosis = described_class.call(user:)

    expect(diagnosis.state).to eq(:unknown)
    expect(diagnosis.recovery_action).to include("Refresh")
  end
end
