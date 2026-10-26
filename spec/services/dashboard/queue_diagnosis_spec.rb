# frozen_string_literal: true

require "rails_helper"

RSpec.describe Dashboard::QueueDiagnosis do
  let(:account) { create(:account) }
  let(:user) { create(:user, account:) }
  let(:project) { create(:project, account:, created_by: user, auto_pick_enabled: true) }

  # @spec QUEUE-DELIVERY-DIAGNOSIS-001, QUEUE-DELIVERY-DIAGNOSIS-002
  it "identifies eligible work that has not been seeded without mutating it" do
    issue = create(:issue, project:, github_state: "open", paid_state: "new")

    diagnosis = described_class.call(user:, rendered_count: 0)

    expect(diagnosis.state).to eq(:runnable_unseeded)
    expect(diagnosis.candidate_count).to eq(1)
    expect(diagnosis.queued_count).to eq(0)
    expect(diagnosis.candidates.map(&:issue)).to eq([ issue ])
    expect(AgentRun.where(issue:)).to be_empty
  end

  # @spec QUEUE-DELIVERY-DIAGNOSIS-001
  it "does not call active work a stalled queue" do
    issue = create(:issue, project:, github_state: "open", paid_state: "new")
    create(:agent_run, :running, project:, issue:)

    diagnosis = described_class.call(user:, rendered_count: 0)

    expect(diagnosis.state).to eq(:healthy_active_work)
    expect(diagnosis.active_count).to eq(1)
  end

  # @spec QUEUE-DELIVERY-DIAGNOSIS-003
  it "reports a refresh requirement when persisted queued work is absent from the projection" do
    create(:agent_run, :queued, :manual, project:)

    diagnosis = described_class.call(user:, rendered_count: 0)

    expect(diagnosis.state).to eq(:rendered_stale)
    expect(diagnosis.queued_count).to eq(1)
  end

  # @spec QUEUE-DELIVERY-DIAGNOSIS-001
  it "keeps another tenant's scheduler state out of the diagnosis" do
    other_project = create(:project, account: create(:account), auto_pick_enabled: true)
    create(:agent_run, :queued, :manual, project: other_project)

    diagnosis = described_class.call(user:, rendered_count: 0)

    expect(diagnosis.queued_count).to eq(0)
  end

  # @spec QUEUE-DELIVERY-DIAGNOSIS-001
  it "reports unknown coverage when the canonical eligibility query is unavailable" do
    allow(Dashboard::EligibilityBreakdown).to receive(:call).and_raise(ActiveRecord::StatementInvalid, "database unavailable")

    diagnosis = described_class.call(user:, rendered_count: 0)

    expect(diagnosis.state).to eq(:unknown)
    expect(diagnosis.action).to include("Refresh")
  end
end
