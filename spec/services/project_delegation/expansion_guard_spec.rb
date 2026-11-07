# frozen_string_literal: true

require "rails_helper"

# @spec PROJECT-DELEGATION-007
RSpec.describe ProjectDelegation::ExpansionGuard do
  let(:account) { create(:account) }
  let(:project) { create(:project, account:) }
  let(:enrollment) do
    create(:delegation_pilot_enrollment, project:, enrolled_at: 15.days.ago)
  end

  let(:baseline_metrics) do
    {
      "inbox_decisions" => 100,
      "completed_issues" => 10,
      "decisions_per_completed_issue" => 10.0,
      "median_decision_seconds" => 3600.0,
      "p90_decision_seconds" => 7200.0,
      "admitted_issues" => 12,
      "completed_issue_rate" => 0.8,
      "reversal_count" => 0,
      "reversal_rate" => 0.0,
      "delegated_reversal_count" => 0
    }
  end
  let(:pilot_metrics) do
    baseline_metrics.merge(
      "inbox_decisions" => 63,
      "completed_issues" => 30,
      "decisions_per_completed_issue" => 2.1,
      "admitted_issues" => 36,
      "completed_issue_rate" => 0.78
    )
  end

  def snapshot(posture:, metrics:, window_ended_at: 1.hour.ago)
    create(:delegation_pilot_metric_snapshot,
      project:,
      enrollment:,
      posture:,
      metrics:,
      window_started_at: posture == "conservative_baseline" ? 45.days.ago : enrollment.enrolled_at,
      window_ended_at: window_ended_at)
  end

  def record_complete_evidence
    snapshot(posture: "conservative_baseline", metrics: baseline_metrics)
    snapshot(posture: "bounded_delivery", metrics: pilot_metrics)
  end

  def guard
    described_class.call(project:)
  end

  before do
    FeatureFlags.enable!(:automation_phases, project:)
    FeatureFlags.enable!(:project_delegation, project:)
  end

  it "keeps broadening disabled by default with no enrollment" do
    result = guard

    expect(result).to be_blocked
    expect(result.reasons).to include(:broadening_disabled_by_default)
  end

  it "keeps broadening disabled while the rollout guards are off" do
    enrollment
    FeatureFlags.disable!(:project_delegation, project:)

    result = guard

    expect(result).to be_blocked
    expect(result.reasons).to include(:project_delegation_disabled)
  end

  it "keeps broadening disabled while the pilot is paused" do
    enrollment.update!(status: "paused", pause_reason: "material_reversal", paused_at: Time.current)
    record_complete_evidence

    result = guard

    expect(result).to be_blocked
    expect(result.reasons).to include(:expansion_paused)
    expect(result.pause_reason).to eq("material_reversal")
  end

  it "requires complete baseline and pilot metric evidence" do
    enrollment
    snapshot(posture: "bounded_delivery", metrics: pilot_metrics)

    result = guard

    expect(result).to be_blocked
    expect(result.pause_reason).to eq("missing_evidence")
  end

  it "treats evidence without the comparison inputs as missing evidence" do
    enrollment
    snapshot(posture: "conservative_baseline", metrics: baseline_metrics.except("decisions_per_completed_issue"))
    snapshot(posture: "bounded_delivery", metrics: pilot_metrics)

    result = guard

    expect(result).to be_blocked
    expect(result.pause_reason).to eq("missing_evidence")
  end

  it "treats a baseline with no comparison population as missing evidence" do
    enrollment
    snapshot(posture: "conservative_baseline", metrics: baseline_metrics.merge("completed_issues" => 0))
    snapshot(posture: "bounded_delivery", metrics: pilot_metrics)

    result = guard

    expect(result.pause_reason).to eq("missing_evidence")
  end

  it "keeps measuring a young pilot instead of pausing it" do
    enrollment
    snapshot(posture: "conservative_baseline", metrics: baseline_metrics)
    snapshot(posture: "bounded_delivery",
      metrics: pilot_metrics.merge(
        "inbox_decisions" => 0,
        "completed_issues" => 0,
        "decisions_per_completed_issue" => nil,
        "median_decision_seconds" => nil,
        "admitted_issues" => 0,
        "completed_issue_rate" => nil
      ), window_ended_at: Time.current)

    result = guard

    expect(result).to be_blocked
    expect(result.pause_reason).to be_nil
    expect(result.reasons).to include(:insufficient_completed_issues)
  end

  it "pauses on a reversal attributable to delegated work" do
    enrollment
    record_complete_evidence
    snapshot(posture: "bounded_delivery",
      metrics: pilot_metrics.merge("delegated_reversal_count" => 1), window_ended_at: Time.current)

    result = guard

    expect(result).to be_blocked
    expect(result.pause_reason).to eq("material_reversal")
  end

  it "requires the review volume and window before broadening" do
    enrollment
    record_complete_evidence
    snapshot(posture: "bounded_delivery",
      metrics: pilot_metrics.merge("completed_issues" => 29), window_ended_at: Time.current)

    expect(guard.reasons).to include(:insufficient_completed_issues)

    enrollment.update!(enrolled_at: 13.days.ago)

    expect(guard.reasons).to include(:review_window_too_short)
  end

  it "requires at least a 25% reduction in Inbox decisions per completed issue" do
    enrollment
    record_complete_evidence
    snapshot(posture: "bounded_delivery",
      metrics: pilot_metrics.merge("decisions_per_completed_issue" => 8.0), window_ended_at: Time.current)

    expect(guard.reasons).to include(:inbox_decision_reduction_unmet)
  end

  it "rejects an increase in median decision time" do
    enrollment
    record_complete_evidence
    snapshot(posture: "bounded_delivery",
      metrics: pilot_metrics.merge("median_decision_seconds" => 3601.0), window_ended_at: Time.current)

    expect(guard.reasons).to include(:median_decision_time_increased)
  end

  it "rejects a completion-rate decline beyond five percentage points" do
    enrollment
    record_complete_evidence
    snapshot(posture: "bounded_delivery",
      metrics: pilot_metrics.merge("completed_issue_rate" => 0.74), window_ended_at: Time.current)

    expect(guard.reasons).to include(:completion_rate_decline_exceeded)
  end

  it "permits broadening only when every RDR-080 threshold is met" do
    enrollment
    record_complete_evidence
    snapshot(posture: "bounded_delivery", metrics: pilot_metrics, window_ended_at: Time.current)

    result = guard

    expect(result).to be_permitted
    expect(result.reasons).to eq([])
  end

  it "accepts the boundary reduction of exactly 25%" do
    enrollment
    record_complete_evidence
    snapshot(posture: "bounded_delivery",
      metrics: pilot_metrics.merge("decisions_per_completed_issue" => 7.5), window_ended_at: Time.current)

    expect(guard).to be_permitted
  end
end
