# frozen_string_literal: true

require "rails_helper"

# @spec PROJECT-DELEGATION-007
RSpec.describe ProjectDelegation::ExpansionGuard do
  let(:account) { create(:account) }
  let(:project) { create(:project, account:) }

  before do
    FeatureFlags.enable!(:automation_phases, project:)
    FeatureFlags.enable!(:project_delegation, project:)
  end

  it "keeps broadening disabled until the pilot threshold is met" do
    decision = described_class.call(project:)

    expect(decision).to be_blocked
    expect(decision.reason).to include("minimum_completed_issues")
  end

  it "permits expansion after the threshold and baseline comparison pass" do
    30.times do |index|
      revision = "intent-#{index}"
      ProjectDelegationMetric.create!(
        project:, event_type: "issue_completed", cohort: "pilot", issue_key: "pilot-#{index}",
        intent_revision: revision, acceptance_revision: revision, evidence_revision: revision,
        occurred_at: 15.days.ago + index.minutes
      )
      ProjectDelegationMetric.create!(
        project:, event_type: "issue_completed", cohort: "baseline", issue_key: "base-#{index}",
        intent_revision: revision, acceptance_revision: revision, evidence_revision: revision,
        occurred_at: 15.days.ago + index.minutes
      )
      ProjectDelegationMetric.create!(
        project:, event_type: "inbox_decision", cohort: "baseline", issue_key: "base-#{index}",
        intent_revision: revision, acceptance_revision: revision, evidence_revision: revision,
        occurred_at: 15.days.ago + index.minutes
      )
    end

    decision = described_class.call(project:)

    expect(decision).to be_permitted
  end

  it "pauses when a material reversal is recorded" do
    create(:project_delegation_metric, project:, event_type: "material_reversal", occurred_at: 15.days.ago)

    decision = described_class.call(project:)

    expect(decision).to be_blocked
    expect(decision.reason).to include("material_reversal")
  end
end
