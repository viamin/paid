# frozen_string_literal: true

require "rails_helper"

RSpec.describe Dashboard::QueueDiagnosis do
  let(:user) { create(:user) }
  let(:project) { create(:project, account: user.account, created_by: user, auto_pick_enabled: true) }

  # @spec QUEUE-HANDOFF-001
  it "reports eligible work without a scheduler handoff as unseeded" do
    issue = create(:issue, project:, github_state: "open", paid_state: "new")

    diagnosis = described_class.call(user:)

    expect(diagnosis.state).to eq(:unseeded_work)
    expect(diagnosis.eligible_count).to eq(1)
    expect(diagnosis.queued_count).to eq(0)
    expect(diagnosis.unseeded_issue_ids).to eq([ issue.id ])
  end

  # @spec QUEUE-HANDOFF-001
  it "reports active work without a waiting backlog as healthy" do
    issue = create(:issue, project:, github_state: "open", paid_state: "new")
    create(:agent_run, :running, :automatic, project:, issue:)

    diagnosis = described_class.call(user:)

    expect(diagnosis.state).to eq(:active_work)
    expect(diagnosis.active_count).to eq(1)
    expect(diagnosis.unseeded_issue_ids).to be_empty
  end

  # @spec QUEUE-HANDOFF-001
  it "reports held work without calling it an empty backlog" do
    blocker = create(:issue, project:, github_state: "open", paid_state: "new", labels: [ "tracking" ])
    create(:issue, project:, github_state: "open", paid_state: "new", labels: [ "tracking" ]) do |issue|
      create(:issue_dependency, issue:, depends_on_issue: blocker)
    end

    diagnosis = described_class.call(user:)

    expect(diagnosis.state).to eq(:held_work)
    expect(diagnosis.open_count).to eq(2)
  end

  # @spec QUEUE-HANDOFF-002
  it "returns unknown coverage when eligibility diagnosis fails" do
    allow(Dashboard::EligibilityBreakdown).to receive(:call).and_raise(ActiveRecord::ConnectionNotEstablished)

    diagnosis = described_class.call(user:)

    expect(diagnosis.state).to eq(:unknown)
    expect(diagnosis.refresh_recommended?).to be(true)
  end
end
