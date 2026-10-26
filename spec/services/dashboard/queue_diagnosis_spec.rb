# frozen_string_literal: true

require "rails_helper"

RSpec.describe Dashboard::QueueDiagnosis do
  # @spec QUEUE-HANDOFF-001
  it "reports runnable work that has not been seeded without calling it an empty backlog" do
    project = create(:project, auto_pick_enabled: true)
    issue = create(:issue, project:, github_state: "open", paid_state: "new")
    breakdown = Dashboard::EligibilityBreakdown::ProjectBreakdown.new(
      project:, total_open: 1, eligible: 1, queued: 0, running: 0, blockers: []
    )

    diagnosis = described_class.call(breakdowns: [ breakdown ])

    expect(diagnosis.state).to eq(:runnable_unseeded)
    expect(diagnosis.eligible).to eq(1)
    expect(diagnosis.queued).to eq(0)
    expect(diagnosis.issues).to eq([ issue.id ])
  end

  # @spec QUEUE-HANDOFF-001
  it "treats running work with no waiting backlog as healthy" do
    project = create(:project, auto_pick_enabled: true)
    breakdown = Dashboard::EligibilityBreakdown::ProjectBreakdown.new(
      project:, total_open: 1, eligible: 0, queued: 0, running: 1, blockers: []
    )

    expect(described_class.call(breakdowns: [ breakdown ]).state).to eq(:healthy_active_work)
  end

  # @spec QUEUE-HANDOFF-002
  it "retains multiple blocker sources for an excluded issue" do
    project = create(:project, auto_pick_enabled: true)
    issue = create(:issue, project:, github_state: "open", paid_state: "new", labels: [ "tracking" ])
    blocker = Dashboard::EligibilityBreakdown::Blocker.new(issue:, reasons: %i[skip_label dependency])
    breakdown = Dashboard::EligibilityBreakdown::ProjectBreakdown.new(
      project:, total_open: 1, eligible: 0, queued: 0, running: 0, blockers: [ blocker ]
    )

    diagnosis = described_class.call(breakdowns: [ breakdown ])

    expect(diagnosis.state).to eq(:blocked)
    expect(diagnosis.blockers.first.issue).to eq(issue)
    expect(diagnosis.blockers.first.reasons).to contain_exactly(:skip_label, :dependency)
  end

  # @spec QUEUE-HANDOFF-003
  it "reports unknown coverage when the eligibility source failed" do
    expect(described_class.unavailable(error: "database unavailable").state).to eq(:unknown)
  end
end
