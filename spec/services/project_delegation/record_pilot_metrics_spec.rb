# frozen_string_literal: true

require "rails_helper"

# @spec PROJECT-DELEGATION-007
RSpec.describe ProjectDelegation::RecordPilotMetrics do
  let(:account) { create(:account) }
  let(:project) { create(:project, account:) }
  let(:user) { create(:user, account:) }
  let(:enrollment) { create(:delegation_pilot_enrollment, project:, enrolled_by: user, enrolled_at: 15.days.ago) }
  let(:window_started_at) { 15.days.ago }
  let(:window_ended_at) { 1.day.ago }

  it "persists a revision-aware snapshot with metrics, exclusions, and revisions" do
    issue = create(:issue, project:, paid_state: "completed", updated_at: 2.days.ago)
    create(:notification, account:, subject: issue, severity: :error, blocking: true,
      created_at: 3.days.ago, resolved_at: 1.day.ago)

    snapshot = described_class.call(enrollment:, posture: "bounded_delivery",
      window_started_at:, window_ended_at:)

    expect(snapshot).to be_persisted
    expect(snapshot.posture).to eq("bounded_delivery")
    expect(snapshot.metrics).to include(
      "inbox_decisions" => 1,
      "completed_issues" => 1,
      "decisions_per_completed_issue" => 1.0
    )
    expect(snapshot.revisions).to include("issues_digest", "joined_issue_ids")
    expect(snapshot.window_started_at).to be_within(1.second).of(window_started_at)
    expect(snapshot.window_ended_at).to be_within(1.second).of(window_ended_at)
  end

  it "records the conservative baseline posture for the pre-enrollment window" do
    snapshot = described_class.call(enrollment:, posture: "conservative_baseline",
      window_started_at: 45.days.ago, window_ended_at: 15.days.ago)

    expect(snapshot.posture).to eq("conservative_baseline")
    expect(enrollment.snapshots.conservative_baseline).to exist
  end

  it "is idempotent per enrollment, posture, and window" do
    attributes = { enrollment:, posture: "bounded_delivery",
      window_started_at:, window_ended_at: }

    first = described_class.call(**attributes)
    second = described_class.call(**attributes)

    expect(second.id).to eq(first.id)
    expect(enrollment.snapshots.where(posture: "bounded_delivery").count).to eq(1)
  end
end
