# frozen_string_literal: true

require "rails_helper"

# @spec STAGED-CLOSEOUT-ADOPTION-008
RSpec.describe Automation::EffectivePolicy do
  let(:account) { create(:account) }
  let(:owner) { create(:user, :owner, account:) }
  let(:project) { create(:project, account:) }
  let(:issue) { create(:issue, project:) }
  let!(:recipe) { create(:pre_commit_requirement, project:, account: project.account, enabled: true) }
  let(:mapping_attributes) do
    {
      criterion_key: "The report renders", stage: "merged_revision", phase: "release_deployment",
      target_shape: "source_pr_merged_revision", execution_path: "technical_prerequisite",
      target_key: recipe.id, freshness_seconds: 3600
    }
  end

  before do
    allow(Github::ReviewBotInstallationToken).to receive(:configured?).and_return(true)
    FeatureFlags.enable!(:automation_phases, project:)
    create(:agent_run, :completed, project:, issue:, reconciliation: { "assessment" => {
      "source_revision" => PartialCloseouts::Assessment.source_revision_for(issue),
      "intent_revision" => PartialCloseouts::Assessment.intent_revision_for(issue),
      "criteria" => [ { "criterion" => "The report renders", "state" => "unmet" } ], "gaps" => []
    } })
    plan = Configuration::Profiles::Planner.call(profile: Configuration::Profiles::SoloAutomated, project:, actor: owner)
    Configuration::Profiles::Applier.call(plan:, project:, actor: owner)
  end

  def approve_mapping
    StagedCloseoutAdoption::Mappings.approve(project:, actor: owner, issue:, attributes: mapping_attributes)
  end

  it "permits the report-only staged verification action in its owning phase" do
    mapping = approve_mapping

    expect(
      described_class.call(project:, phase: mapping.phase, work_item: issue, trigger: :automatic)
    ).to be_permitted
    expect(StagedCloseoutAdoption::Mappings.eligible_for(mapping:, project:, issue:)).to be_eligible
  end

  it "does not enable a deployment executor or the Operations phase" do
    settings = Automation::PhaseSettings.call(project.reload)

    expect(settings.deployment_enabled?).to be(false)
    expect(settings.phases[Automation::Phases::OPERATIONS]).to be(false)
    expect(
      described_class.call(project:, phase: Automation::Phases::OPERATIONS, work_item: issue,
        trigger: :automatic).blocked?
    ).to be(true)
  end

  it "does not bypass a disabled owning phase" do
    project.update!(
      Automation::PhaseSettings::SETTINGS_KEY => {
        Automation::PhaseSettings::PHASES_KEY => { Automation::Phases::RELEASE_DEPLOYMENT => false }
      }
    )
    mapping = approve_mapping

    decision = described_class.call(project:, phase: mapping.phase, work_item: issue, trigger: :automatic)
    expect(decision).to be_blocked
    expect(decision.reason).to eq(:phase_disabled)
    expect(StagedCloseoutAdoption::Mappings.eligible_for(mapping:, project:, issue:).reason).to eq("phase_policy_disabled")
  end

  it "reports an inspectable waiting reason when the mapped target becomes unavailable" do
    mapping = approve_mapping
    recipe.update!(enabled: false)

    result = StagedCloseoutAdoption::Mappings.eligible_for(mapping:, project:, issue:)

    expect(result).not_to be_eligible
    expect(result.reason).to eq("recipe is unavailable or unauthorized")
  end

  it "reports an inspectable waiting reason when the approved criterion is absent" do
    mapping = approve_mapping
    create(:agent_run, :completed, project:, issue:, reconciliation: { "assessment" => {
      "source_revision" => PartialCloseouts::Assessment.source_revision_for(issue),
      "intent_revision" => PartialCloseouts::Assessment.intent_revision_for(issue),
      "criteria" => [ { "criterion" => "A replacement criterion", "state" => "unmet" } ], "gaps" => []
    } })

    result = StagedCloseoutAdoption::Mappings.eligible_for(mapping:, project:, issue:)

    expect(result).not_to be_eligible
    expect(result.reason).to eq("criterion_not_current")
  end
end
