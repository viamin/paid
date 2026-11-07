# frozen_string_literal: true

require "rails_helper"

# @spec PROJECT-DELEGATION-007
RSpec.describe DelegationPilotMetricSnapshot do
  let(:account) { create(:account) }
  let(:project) { create(:project, account:) }
  let(:enrollment) { create(:delegation_pilot_enrollment, project:) }

  it "records metrics, exclusions, and revisions for a window" do
    snapshot = create(:delegation_pilot_metric_snapshot, enrollment:, project:,
      metrics: { "completed_issues" => 3 },
      exclusions: [ { "reason" => "auto_released", "count" => 1 } ],
      revisions: { "issues_digest" => "abc" })

    expect(snapshot.metrics).to include("completed_issues" => 3)
    expect(snapshot.exclusions).to include({ "reason" => "auto_released", "count" => 1 })
    expect(snapshot.revisions).to include("issues_digest" => "abc")
  end

  it "rejects unknown postures" do
    snapshot = build(:delegation_pilot_metric_snapshot, enrollment:, project:, posture: "speculative")

    expect(snapshot).not_to be_valid
    expect(snapshot.errors[:posture]).to include(/not included/)
  end

  it "requires the snapshot to belong to the enrollment's project and account" do
    other_project = create(:project, account:)
    snapshot = build(:delegation_pilot_metric_snapshot, enrollment:, project: other_project)

    expect(snapshot).not_to be_valid
    expect(snapshot.errors[:project]).to include(/must match the enrollment/)
  end

  it "allows one snapshot per enrollment, posture, and window end" do
    window_end = 1.day.ago
    create(:delegation_pilot_metric_snapshot, enrollment:, project:,
      posture: "bounded_delivery", window_ended_at: window_end)

    snapshot = build(:delegation_pilot_metric_snapshot, enrollment:, project:,
      posture: "bounded_delivery", window_ended_at: window_end)

    expect(snapshot).not_to be_valid
  end
end
