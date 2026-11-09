# frozen_string_literal: true

require "rails_helper"

# @spec PROJECT-DELEGATION-007
RSpec.describe ProjectDelegation::ExpansionGuard do
  let(:account) { create(:account) }
  let(:owner) { create(:user, :owner, account:) }
  let(:project) { create(:project, :with_github_installation, account:, created_by: owner) }

  def metric_result(available:, metrics:, reason: nil)
    ProjectDelegation::PilotMetrics::Result.new(
      available:, reason:, sample_count: metrics[:completed_issues].to_i, observed_days: 14, metrics:
    )
  end

  it "is default-disabled even when a pilot has not produced evidence" do
    expect(ProjectDelegation::PilotMetrics).not_to receive(:call)

    result = described_class.call(project:)

    expect(result).not_to be_allowed
    expect(result.reason).to eq("expansion_guard_disabled")
    expect(result.to_h).to include(metrics: nil)
  end

  it "pauses on missing evidence" do
    metrics = metric_result(available: false, reason: "no_metric_evidence", metrics: { material_reversals: 0 })
    allow(ProjectDelegation::PilotMetrics).to receive(:call).and_return(metrics)
    FeatureFlags.enable!(:project_delegation_expansion, project:)

    result = described_class.call(project:)

    expect(result).not_to be_allowed
    expect(result.reason).to eq("missing_evidence")
    expect(result).to be_paused
  end

  it "pauses on material reversals" do
    metrics = metric_result(available: true, metrics: {
        material_reversals: 1, security_breaches: 0, tenant_breaches: 0, trust_breaches: 0,
        missing_evidence: 0, decisions_per_completed_issue: 0.5,
        median_decision_time_seconds: 100, completion_rate: 0.96,
        baseline: { decisions_per_completed_issue: 1.0, median_decision_time_seconds: 100, completion_rate: 1.0 }
      })
    allow(ProjectDelegation::PilotMetrics).to receive(:call).and_return(metrics)
    FeatureFlags.enable!(:project_delegation_expansion, project:)

    result = described_class.call(project:)

    expect(result).not_to be_allowed
    expect(result.reason).to eq("material_reversal")
    expect(result).to be_paused
  end

  it "permits expansion only after all RDR-080 thresholds pass" do
    metrics = metric_result(available: true, metrics: {
        material_reversals: 0, security_breaches: 0, tenant_breaches: 0, trust_breaches: 0,
        missing_evidence: 0, decisions_per_completed_issue: 0.5,
        median_decision_time_seconds: 100, completion_rate: 0.96,
        baseline: { decisions_per_completed_issue: 1.0, median_decision_time_seconds: 100, completion_rate: 1.0 }
      })
    allow(ProjectDelegation::PilotMetrics).to receive(:call).and_return(metrics)
    FeatureFlags.enable!(:project_delegation_expansion, project:)

    expect(described_class.call(project:)).to be_allowed
  end

  it "pauses expansion when current decision-time evidence is missing" do
    metrics = metric_result(available: true, metrics: {
        material_reversals: 0, security_breaches: 0, tenant_breaches: 0, trust_breaches: 0,
        missing_evidence: 0, decisions_per_completed_issue: 0.0,
        median_decision_time_seconds: nil, completion_rate: 0.96,
        baseline: { decisions_per_completed_issue: 1.0, median_decision_time_seconds: 100, completion_rate: 1.0 }
      })
    allow(ProjectDelegation::PilotMetrics).to receive(:call).and_return(metrics)
    FeatureFlags.enable!(:project_delegation_expansion, project:)

    result = described_class.call(project:)

    expect(result).not_to be_allowed
    expect(result.reason).to eq("decision_time_missing")
    expect(result).to be_paused
  end

  it "pauses expansion when current completion-rate evidence is missing" do
    metrics = metric_result(available: true, metrics: {
        material_reversals: 0, security_breaches: 0, tenant_breaches: 0, trust_breaches: 0,
        missing_evidence: 0, decisions_per_completed_issue: 0.5,
        median_decision_time_seconds: 100, completion_rate: nil,
        baseline: { decisions_per_completed_issue: 1.0, median_decision_time_seconds: 100, completion_rate: 1.0 }
      })
    allow(ProjectDelegation::PilotMetrics).to receive(:call).and_return(metrics)
    FeatureFlags.enable!(:project_delegation_expansion, project:)

    result = described_class.call(project:)

    expect(result).not_to be_allowed
    expect(result.reason).to eq("completion_rate_missing")
    expect(result).to be_paused
  end

  it "reports reversed threshold evidence as a paused expansion" do
    metrics = metric_result(available: true, metrics: {
        material_reversals: 0, security_breaches: 0, tenant_breaches: 0, trust_breaches: 0,
        missing_evidence: 0, decisions_per_completed_issue: 0.9,
        median_decision_time_seconds: 100, completion_rate: 1.0,
        baseline: { decisions_per_completed_issue: 1.0, median_decision_time_seconds: 100, completion_rate: 1.0 }
      })
    allow(ProjectDelegation::PilotMetrics).to receive(:call).and_return(metrics)
    FeatureFlags.enable!(:project_delegation_expansion, project:)

    result = described_class.call(project:)

    expect(result.reason).to eq("decision_volume_threshold_not_met")
    expect(result).to be_paused
  end

  it "reuses the guard aggregation until the pilot ledger changes" do # @spec PROJECT-DELEGATION-007
    original_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    posture = create(:project_delegation_posture, project:, selected_by: owner, level: "bounded_delivery")
    FeatureFlags.enable!(:automation_phases, project:)
    FeatureFlags.enable!(:project_delegation, project:)
    FeatureFlags.enable!(:project_delegation_expansion, project:)
    ProjectDelegation::PilotMetrics.record(project:, event_type: "issue_completed", event_key: "completed",
      posture:, policy_signature: posture.policy_signature)

    first_queries = count_queries { described_class.call(project:) }
    cached_queries = count_queries { described_class.call(project:) }
    ProjectDelegation::PilotMetrics.record(project:, event_type: "trust_breach", event_key: "breach",
      posture:, policy_signature: posture.policy_signature)
    invalidated_queries = count_queries { described_class.call(project:) }

    expect(first_queries).to be > cached_queries
    expect(cached_queries).to be <= 2
    expect(invalidated_queries).to be > cached_queries
  ensure
    Rails.cache = original_cache
  end
end
