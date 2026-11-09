# frozen_string_literal: true

require "rails_helper"

# @spec PROJECT-DELEGATION-007
RSpec.describe ProjectDelegation::PilotMetrics do
  let(:account) { create(:account) }
  let(:owner) { create(:user, :owner, account:) }
  let(:project) { create(:project, :with_github_installation, account:, created_by: owner) }
  let(:posture) { create(:project_delegation_posture, project:, selected_by: owner, level: "bounded_delivery") }
  let(:policy_signature) { posture.policy_signature }
  let(:now) { Time.zone.parse("2026-11-08 12:00:00") }

  before do
    FeatureFlags.enable!(:automation_phases, project:)
    FeatureFlags.enable!(:project_delegation, project:)
  end

  def record(type, key, baseline: false, occurred_at: now - 15.days, issue: nil, intent_revision: nil,
    acceptance_revision: nil, evidence_revision: nil, **metadata)
    described_class.record(project:, event_type: type, event_key: key, posture:, policy_signature:, issue:,
      baseline:, occurred_at:, intent_revision:, acceptance_revision:, evidence_revision:, metadata: metadata)
  end

  def record_baseline_metrics
    4.times do |index|
      issue = create(:issue, project:)
      record("issue_started", "baseline-started-#{index}", issue:, baseline: true)
      record("issue_completed", "baseline-completed-#{index}", issue:, baseline: true)
    end
    8.times do |index|
      record("human_decision", "baseline-decision-#{index}", issue: create(:issue, project:), baseline: true,
        duration_seconds: 100)
    end
  end

  def record_pilot_metrics
    30.times do |index|
      issue = create(:issue, project:)
      record("issue_started", "started-#{index}", issue:)
      record("issue_completed", "completed-#{index}", issue:)
      record("human_decision", "decision-#{index}", issue:, duration_seconds: 100) if index < 22
    end
    record("decision_reversed", "reversal-1", material: true)
  end

  it "stores each metric with posture and evidence revisions" do
    record("human_decision", "decision-1", intent_revision: "intent-2", acceptance_revision: "accept-3",
      evidence_revision: "evidence-4", duration_seconds: 12)

    event = InboxHistoryEvent.find_by!(event_key: "decision-1")
    expect(event).to have_attributes(source: "project_delegation_pilot", revision: posture.revision.to_s)
    expect(event.metadata).to include(
      "posture_revision" => posture.revision,
      "policy_signature" => policy_signature,
      "intent_revision" => "intent-2",
      "acceptance_revision" => "accept-3",
      "evidence_revision" => "evidence-4"
    )
  end

  it "keeps evidence unavailable until the pilot sample and observation period exist" do
    record("issue_completed", "completed-1")

    result = described_class.call(project:, now:)

    expect(result).not_to be_available
    expect(result.reason).to eq("minimum_completed_issues_not_met")
  end

  it "calculates revision-aware decision, completion, and reversal metrics" do
    record_baseline_metrics
    record_pilot_metrics

    result = described_class.call(project:, now:)

    expect(result.metrics).to include(
      completed_issues: 30,
      human_decisions: 22,
      reversals: 1,
      material_reversals: 1,
      completion_rate: 1.0
    )
    expect(result.metrics[:baseline][:decisions_per_completed_issue]).to eq(2.0)
  end

  it "does not combine evidence from an earlier authority revision" do # @spec PROJECT-DELEGATION-007
    30.times { |index| record("issue_completed", "old-completed-#{index}") }
    posture.update!(revision: 2)
    record("issue_completed", "current-completed")

    result = described_class.call(project:, now:)

    expect(result.sample_count).to eq(1)
    expect(result.reason).to eq("minimum_completed_issues_not_met")
  end

  it "keeps lifecycle denominators when an issue evidence revision advances" do # @spec PROJECT-DELEGATION-007
    issue = create(:issue, project:)
    record("human_decision", "decision", issue:, evidence_revision: "evidence-1", duration_seconds: 60)
    record("issue_started", "started", issue:, evidence_revision: "evidence-1")
    record("issue_completed", "completed", issue:, evidence_revision: "evidence-2")

    metrics = described_class.call(project:, now:).metrics

    expect(metrics).to include(completed_issues: 1, human_decisions: 1, completion_rate: 1.0)
    expect(metrics[:decisions_per_completed_issue]).to eq(1.0)
    expect(metrics[:median_decision_time_seconds]).to eq(60.0)
  end

  it "counts every resolved decision in the current authority revision" do # @spec PROJECT-DELEGATION-007
    issue = create(:issue, project:)
    record("issue_completed", "completed", issue:)
    record("human_decision", "decision-1", issue:, duration_seconds: 60)
    record("human_decision", "decision-2", issue:, duration_seconds: 120)

    metrics = described_class.call(project:, now:).metrics

    expect(metrics).to include(completed_issues: 1, human_decisions: 2, decisions_per_completed_issue: 2.0)
    expect(metrics[:median_decision_time_seconds]).to eq(90.0)
  end
end
