# frozen_string_literal: true

require "rails_helper"

# @spec PROJECT-DELEGATION-007
RSpec.describe ProjectDelegation::PilotMetrics do
  let(:account) { create(:account) }
  let(:project) { create(:project, account:) }

  def record(event_type, attributes = {})
    ProjectDelegationMetric.create!(
      { project:, event_type:, cohort: "pilot", intent_revision: "intent-1",
        acceptance_revision: "acceptance-1", evidence_revision: "evidence-1",
        occurred_at: Time.current }.merge(attributes)
    )
  end

  it "joins decisions to completions by immutable revisions" do
    completed_at = 15.days.ago
    record("issue_started", occurred_at: 16.days.ago)
    record("inbox_decision", issue_key: "issue-1", occurred_at: 15.days.ago - 2.hours)
    record("issue_completed", issue_key: "issue-1", occurred_at: completed_at)
    record("inbox_decision", issue_key: "issue-2", intent_revision: "intent-old", occurred_at: 15.days.ago - 1.hour)
    record("issue_completed", issue_key: "issue-2", occurred_at: completed_at)

    snapshot = described_class.call(project:)

    expect(snapshot.completed_issues).to eq(2)
    expect(snapshot.inbox_decisions).to eq(1)
    expect(snapshot.decision_rate).to eq(0.5)
  end

  it "reports safety pauses and evidence completeness" do
    record("issue_completed", occurred_at: 15.days.ago)
    record("trust_breach", reason_code: "untrusted_actor")
    record("evidence_missing", reason_code: "assessment_unavailable")

    snapshot = described_class.call(project:)

    expect(snapshot.pause_reasons).to contain_exactly("trust_breach", "missing_evidence")
    expect(snapshot.evidence_complete?).to be(false)
  end
end
