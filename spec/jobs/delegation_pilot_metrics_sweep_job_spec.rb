# frozen_string_literal: true

require "rails_helper"

# @spec PROJECT-DELEGATION-007
RSpec.describe DelegationPilotMetricsSweepJob do
  let(:account) { create(:account) }
  let(:project) { create(:project, account:) }
  let(:enrollment) { create(:delegation_pilot_enrollment, project:, enrolled_at: 15.days.ago) }

  before do
    FeatureFlags.enable!(:automation_phases, project:)
    FeatureFlags.enable!(:project_delegation, project:)
  end

  def baseline_snapshot(metrics = {})
    create(:delegation_pilot_metric_snapshot, project:, enrollment:,
      posture: "conservative_baseline",
      window_started_at: 45.days.ago, window_ended_at: 15.days.ago,
      metrics: {
        "inbox_decisions" => 100,
        "completed_issues" => 10,
        "decisions_per_completed_issue" => 10.0,
        "median_decision_seconds" => 3600.0,
        "admitted_issues" => 12,
        "completed_issue_rate" => 0.8,
        "reversal_count" => 0,
        "reversal_rate" => 0.0,
        "delegated_reversal_count" => 0
      }.merge(metrics))
  end

  it "records a pilot snapshot for every active enrollment" do
    baseline_snapshot

    described_class.perform_now

    snapshot = enrollment.snapshots.bounded_delivery.order(:created_at).last
    expect(snapshot).to be_present
    expect(snapshot.window_started_at).to be_within(1.second).of(enrollment.enrolled_at)
    expect(snapshot.window_ended_at).to be_within(1.second).of(Time.current)
  end

  it "pauses the pilot when no baseline evidence exists" do
    enrollment

    described_class.perform_now

    expect(enrollment.reload).to be_paused
    expect(enrollment.pause_reason).to eq("missing_evidence")
    expect(Notification.find_by(source: ProjectDelegation::PauseExpansion::NOTIFICATION_SOURCE)).to be_blocking
  end

  it "pauses the pilot when the recorded evidence shows a delegated reversal" do
    baseline_snapshot
    reopened = create(:issue, project:, paid_state: "manual_review",
      manual_review_reason: Issue::REOPEN_REVIEW_REQUIRED_REASON)
    create(:bounded_delegated_action, project:, issue: reopened, created_at: 20.days.ago)

    described_class.perform_now

    expect(enrollment.reload.pause_reason).to eq("material_reversal")
    expect(enrollment.snapshots.bounded_delivery.last.metrics["delegated_reversal_count"]).to eq(1)
  end

  it "leaves a young pilot enrolled while its evidence accumulates" do
    baseline_snapshot

    described_class.perform_now

    expect(enrollment.reload).to be_active
    expect(Notification.where(source: ProjectDelegation::PauseExpansion::NOTIFICATION_SOURCE)).to be_empty
  end

  it "skips paused enrollments and keeps their evidence" do
    enrollment.update!(status: "paused", pause_reason: "missing_evidence", paused_at: Time.current)

    described_class.perform_now

    expect(enrollment.snapshots.bounded_delivery.where("window_ended_at > ?", 1.minute.ago)).to be_empty
  end

  it "continues the sweep when one enrollment fails" do
    failing = enrollment
    healthy = create(:delegation_pilot_enrollment, project: create(:project, account:), enrolled_at: 15.days.ago)
    allow(ProjectDelegation::RecordPilotMetrics).to receive(:call).and_wrap_original do |method, **kwargs|
      raise "sweep exploded" if kwargs.fetch(:enrollment) == failing

      method.call(**kwargs)
    end

    described_class.perform_now

    expect(healthy.snapshots.bounded_delivery.last).to be_present
  end
end
