# frozen_string_literal: true

require "rails_helper"

# @spec PROJECT-DELEGATION-007
RSpec.describe ProjectDelegation::ExpansionGuard do
  let(:account) { create(:account) }
  let(:owner) { create(:user, :owner, account:) }
  let(:project) { create(:project, :with_github_installation, account:, created_by: owner) }

  it "is default-disabled even when a pilot has not produced evidence" do
    result = described_class.call(project:)

    expect(result).not_to be_allowed
    expect(result.reason).to eq("expansion_guard_disabled")
  end

  it "pauses on missing evidence and material reversals" do
    metrics = instance_double(ProjectDelegation::PilotMetrics::Result,
      available?: false, reason: "no_metric_evidence", metrics: { material_reversals: 0 })
    allow(ProjectDelegation::PilotMetrics).to receive(:call).and_return(metrics)
    FeatureFlags.enable!(:project_delegation_expansion, project:)

    result = described_class.call(project:)

    expect(result).not_to be_allowed
    expect(result.reason).to eq("missing_evidence")
    expect(result).to be_paused
  end

  it "permits expansion only after all RDR-080 thresholds pass" do
    metrics = instance_double(ProjectDelegation::PilotMetrics::Result,
      available?: true,
      metrics: {
        material_reversals: 0, security_breaches: 0, tenant_breaches: 0, trust_breaches: 0,
        missing_evidence: 0, decisions_per_completed_issue: 0.5,
        median_decision_time_seconds: 100, completion_rate: 0.96,
        baseline: { decisions_per_completed_issue: 1.0, median_decision_time_seconds: 100, completion_rate: 1.0 }
      })
    allow(ProjectDelegation::PilotMetrics).to receive(:call).and_return(metrics)
    FeatureFlags.enable!(:project_delegation_expansion, project:)

    expect(described_class.call(project:)).to be_allowed
  end
end
