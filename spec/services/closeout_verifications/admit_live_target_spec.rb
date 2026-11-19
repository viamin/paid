# frozen_string_literal: true

require "rails_helper"

RSpec.describe CloseoutVerifications::AdmitLiveTarget do
  let(:project) { create(:project) }
  let(:maintainer) { create(:user, :owner, account: project.account) }
  let(:issue) { create(:issue, project:) }
  let(:target_revision) { "development:fixture:content" }

  before do
    FeatureFlags.enable!(:automation_phases, project:)
    project.update!(automation_phase_settings: { "phases" => { "operations" => true } })
    StagedCloseoutAdoption::Enroll.call(project:, actor: maintainer, enabled: true)
    create(:agent_run, :completed, project:, issue:, reconciliation: { "assessment" => {
      "source_revision" => PartialCloseouts::Assessment.source_revision_for(issue),
      "intent_revision" => PartialCloseouts::Assessment.intent_revision_for(issue),
      "criteria" => [ { "criterion" => "Live evidence", "state" => "unmet" } ], "gaps" => []
    } })
  end

  def mapping
    StagedCloseoutAdoption::Mappings.approve(project:, actor: maintainer, issue:, attributes: {
      criterion_key: "Live evidence", stage: "live_environment", phase: "operations", target_shape: "live_signal",
      execution_path: "trusted_measurement", target_key: "agent_planning_hold_reconciliation_closed_count",
      environment_class: "development", freshness_seconds: 60
    })
  end

  # @spec STAGED-CLOSEOUT-ADOPTION-012
  it "admits one signal-bound run and converges duplicate signal delivery" do
    reviewed = mapping
    first = described_class.call(project:, target_revision:)
    second = described_class.call(project:, target_revision:)

    expect(first.runs).to contain_exactly(an_object_having_attributes(closeout_mapping_id: reviewed.id,
      closeout_environment: "development", closeout_target_revision: target_revision))
    expect(second.runs).to be_empty
    expect(AgentRun.where(goal: "closeout_verification").count).to eq(1)
  end

  # @spec STAGED-CLOSEOUT-ADOPTION-012
  it "keeps a changed environment target as a distinct run and refuses an absent signal" do
    mapping
    described_class.call(project:, target_revision:)
    changed = described_class.call(project:, target_revision: "development:fixture:changed")
    missing = described_class.call(project:, target_revision: nil)

    expect(changed).to be_admitted
    expect(missing.reason).to eq("live_target_unconfirmed")
    expect(AgentRun.where(goal: "closeout_verification").count).to eq(2)
  end

  # @spec STAGED-CLOSEOUT-ADOPTION-012
  it "does not admit another tenant's mapping" do
    mapping
    other = create(:project)

    expect(described_class.call(project: other, target_revision:).runs).to be_empty
    expect(AgentRun.where(project: other, goal: "closeout_verification")).to be_empty
  end
end
