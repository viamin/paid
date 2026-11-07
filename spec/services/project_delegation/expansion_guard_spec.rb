# frozen_string_literal: true

require "rails_helper"

# @spec PROJECT-DELEGATION-007
RSpec.describe ProjectDelegation::ExpansionGuard do
  let(:account) { create(:account) }
  let(:project) { create(:project, account:) }

  def enable_guards
    FeatureFlags.enable!(:automation_phases, project:)
    FeatureFlags.enable!(:project_delegation, project:)
  end

  def record_baseline(**overrides)
    ProjectDelegation::RecordPilotMetrics.call(
      project:,
      posture: "conservative",
      window_started_at: 60.days.ago,
      window_ended_at: 46.days.ago,
      completed_issues: 20,
      total_issues: 25,
      decision_seconds: Array.new(100) { |i| 3000 + i },
      reversals: [],
      exclusions: {},
      revisions: {
        "intent_revision" => "sha256:#{Digest::SHA256.hexdigest("baseline-intent")}",
        "acceptance_revision" => "sha256:#{Digest::SHA256.hexdigest("baseline-acceptance")}",
        "evidence_revision" => "sha256:#{Digest::SHA256.hexdigest("baseline-evidence")}"
      },
      **overrides
    )
  end

  def record_pilot(**overrides)
    ProjectDelegation::RecordPilotMetrics.call(
      project:,
      posture: "bounded_delivery",
      window_started_at: 30.days.ago,
      window_ended_at: 1.day.ago,
      completed_issues: 30,
      total_issues: 32,
      decision_seconds: Array.new(30) { |i| 3000 + i },
      reversals: [],
      exclusions: {},
      revisions: {
        "intent_revision" => "sha256:#{Digest::SHA256.hexdigest("pilot-intent")}",
        "acceptance_revision" => "sha256:#{Digest::SHA256.hexdigest("pilot-acceptance")}",
        "evidence_revision" => "sha256:#{Digest::SHA256.hexdigest("pilot-evidence")}"
      },
      **overrides
    )
  end

  it "defines the project_delegation rollout flag default-off" do
    definition = FeatureFlags.definition(:project_delegation)

    expect(definition.name).to eq(:project_delegation)
    expect(definition.rollout_plan).to include("Default-off")
    expect(FeatureFlags.enabled?(:project_delegation, project:)).to be(false)
  end

  it "keeps broadening disabled by default for a project that never opted in" do
    result = described_class.call(project:)

    expect(result).to be_blocked
    expect(result.reasons).to include(:rollout_guard_disabled)
  end

  it "stays disabled while both rollout guards are required" do
    FeatureFlags.enable!(:automation_phases, project:)

    result = described_class.call(project:)

    expect(result).to be_blocked
    expect(result.reasons).to include(:rollout_guard_disabled)
  end

  it "blocks without recorded pilot and baseline metrics" do
    enable_guards

    result = described_class.call(project:)

    expect(result).to be_blocked
    expect(result.reasons).to contain_exactly(:missing_pilot_metrics, :missing_baseline_metrics)
  end

  it "blocks when the pilot review window has fewer than 30 completed issues" do
    enable_guards
    record_baseline
    record_pilot(completed_issues: 29, total_issues: 32)

    result = described_class.call(project:)

    expect(result).to be_blocked
    expect(result.reasons).to contain_exactly(:insufficient_completed_issues)
  end

  it "blocks when the pilot window is shorter than 14 days" do
    enable_guards
    record_baseline
    record_pilot(window_started_at: 10.days.ago, window_ended_at: 1.day.ago)

    result = described_class.call(project:)

    expect(result).to be_blocked
    expect(result.reasons).to contain_exactly(:insufficient_review_window)
  end

  it "blocks when Inbox decisions per completed issue do not fall by 25 percent" do
    enable_guards
    record_baseline
    record_pilot(decision_seconds: Array.new(120) { |i| 2000 + i })

    result = described_class.call(project:)

    expect(result).to be_blocked
    expect(result.reasons).to contain_exactly(:decision_volume_not_reduced)
  end

  it "blocks when median decision time increases versus baseline" do
    enable_guards
    record_baseline(decision_seconds: Array.new(100) { |i| 1000 + i })
    record_pilot(decision_seconds: Array.new(30) { |i| 3000 + i })

    result = described_class.call(project:)

    expect(result).to be_blocked
    expect(result.reasons).to contain_exactly(:median_decision_time_increased)
  end

  it "blocks when completion rate declines by more than 5 percentage points" do
    enable_guards
    record_baseline
    record_pilot(total_issues: 41)

    result = described_class.call(project:)

    expect(result).to be_blocked
    expect(result.reasons).to contain_exactly(:completion_rate_declined)
  end

  it "blocks when a material reversal is attributable to delegated work" do
    enable_guards
    record_baseline
    record_pilot(reversals: [
      {
        "settled_revision" => "sha256:#{Digest::SHA256.hexdigest("settled")}",
        "reversing_revision" => "sha256:#{Digest::SHA256.hexdigest("reversing")}",
        "material" => true,
        "attributable_to_delegated_work" => true
      }
    ])

    result = described_class.call(project:)

    expect(result).to be_blocked
    expect(result.reasons).to contain_exactly(:material_reversal_attributable)
  end

  it "blocks on missing metric evidence rather than treating it as passing" do
    enable_guards
    record_baseline
    record_pilot
    ProjectDelegation::PilotMetric.latest_for(project, "bounded_delivery")
      .update!(median_decision_seconds: nil, p90_decision_seconds: nil)

    result = described_class.call(project:)

    expect(result).to be_blocked
    expect(result.reasons).to contain_exactly(:missing_evidence)
  end

  it "permits broadening only when every RDR-080 threshold is met" do
    enable_guards
    baseline = record_baseline
    pilot = record_pilot

    result = described_class.call(project:)

    expect(result).to be_allowed
    expect(result.reasons).to be_empty
    expect(result.baseline).to eq(baseline)
    expect(result.pilot).to eq(pilot)
  end

  it "collects every failing threshold reason at once" do
    enable_guards
    record_baseline
    record_pilot(completed_issues: 10, total_issues: 32, decision_seconds: Array.new(40) { |i| 2000 + i })

    result = described_class.call(project:)

    expect(result.reasons).to contain_exactly(
      :insufficient_completed_issues, :decision_volume_not_reduced, :completion_rate_declined
    )
  end

  describe ".paused?" do
    it "is true while an unresolved pause exists and false once a human resolves it" do
      pause = create(:project_delegation_expansion_pause, project:)

      expect(described_class).to be_paused(project)

      pause.update!(resolved_at: Time.current, resolved_by: create(:user, :member, account:))
      expect(described_class).not_to be_paused(project)
    end
  end

  describe ".effective_posture" do
    it "returns conservative while an expansion pause is unresolved" do
      enable_guards
      record_pilot
      create(:project_delegation_expansion_pause, project:)

      expect(described_class.effective_posture(project)).to eq("conservative")
    end

    it "returns conservative unless every guard permits and the project is enrolled" do
      expect(described_class.effective_posture(project)).to eq("conservative")

      enable_guards
      expect(described_class.effective_posture(project)).to eq("conservative")

      record_pilot
      expect(described_class.effective_posture(project)).to eq("bounded_delivery")
    end
  end
end
