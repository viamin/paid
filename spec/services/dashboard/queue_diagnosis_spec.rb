# frozen_string_literal: true

require "rails_helper"

# @spec QUEUE-HANDOFF-001 QUEUE-HANDOFF-002
RSpec.describe Dashboard::QueueDiagnosis do
  let(:account) { create(:account) }
  let(:user) { create(:user, account:) }
  let(:project) { create(:project, account:, created_by: user, auto_pick_enabled: true) }

  it "identifies eligible work that has not been seeded" do
    create(:issue, project:, github_state: "open", paid_state: "new")

    diagnosis = described_class.call(user:)

    expect(diagnosis.state).to eq(:runnable_unseeded)
    expect(diagnosis.eligible_count).to eq(1)
    expect(diagnosis.queued_count).to eq(0)
    expect(diagnosis.running_count).to eq(0)
  end

  it "does not call an empty waiting queue a failure while work is active" do
    create(:agent_run, :running, project:, started_at: 1.minute.ago)

    diagnosis = described_class.call(user:)

    expect(diagnosis.state).to eq(:active_work)
    expect(diagnosis.running_count).to eq(1)
  end

  it "reports backend queued work separately from the rendered preview" do
    create(:agent_run, :queued, :manual, project:)

    diagnosis = described_class.call(user:)

    expect(diagnosis.state).to eq(:queued_work)
    expect(diagnosis.queued_count).to eq(1)
  end

  it "reports unavailable coverage when canonical eligibility data fails" do
    allow(Dashboard::EligibilityBreakdown).to receive(:call).and_raise(ActiveRecord::ConnectionNotEstablished)

    diagnosis = described_class.call(user:)

    expect(diagnosis.state).to eq(:unavailable)
    expect(diagnosis.error).to be_present
  end

  it "does not include another tenant's queued work" do
    other_project = create(:project, auto_pick_enabled: true)
    create(:agent_run, :queued, :manual, project: other_project)

    diagnosis = described_class.call(user:)

    expect(diagnosis.queued_count).to eq(0)
  end
end
