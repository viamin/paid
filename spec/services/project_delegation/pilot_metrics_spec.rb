# frozen_string_literal: true

require "rails_helper"

# @spec PROJECT-DELEGATION-007
RSpec.describe ProjectDelegation::PilotMetrics do
  let(:account) { create(:account) }
  let(:owner) { create(:user, :owner, account:) }
  let(:project) { create(:project, :with_github_installation, account:, created_by: owner) }
  let(:posture) { create(:project_delegation_posture, project:, selected_by: owner, level: "bounded_delivery") }
  let(:policy_signature) { "p" * 64 }
  let(:now) { Time.zone.parse("2026-11-08 12:00:00") }

  def record(type, key, baseline: false, occurred_at: now - 15.days, intent_revision: nil,
    acceptance_revision: nil, evidence_revision: nil, **metadata)
    described_class.record(project:, event_type: type, event_key: key, posture:, policy_signature:,
      baseline:, occurred_at:, intent_revision:, acceptance_revision:, evidence_revision:, metadata: metadata)
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
    4.times do |index|
      record("issue_started", "baseline-started-#{index}", baseline: true)
      record("issue_completed", "baseline-completed-#{index}", baseline: true)
    end
    8.times { |index| record("human_decision", "baseline-decision-#{index}", baseline: true, duration_seconds: 100) }
    30.times do |index|
      record("issue_started", "started-#{index}")
      record("issue_completed", "completed-#{index}")
    end
    22.times { |index| record("human_decision", "decision-#{index}", duration_seconds: 100) }
    record("decision_reversed", "reversal-1", material: true)

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
end
