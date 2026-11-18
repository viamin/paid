# frozen_string_literal: true

require "rails_helper"

# @spec AUTOMATION-PHASES-014
RSpec.describe Automation::PhaseRolloutRollback do
  let(:account) { create(:account) }
  let(:project) { create(:project, account:) }
  let(:issue) { create(:issue, project:, github_state: "open") }

  before { FeatureFlags.enable!(:automation_phases, project:) }

  def disable_coding
    project.update!(
      Automation::PhaseSettings::SETTINGS_KEY => {
        Automation::PhaseSettings::PHASES_KEY => { "coding" => false, "merge" => false },
        Automation::PhaseSettings::RELEASE_KEY => false,
        Automation::PhaseSettings::DEPLOYMENT_KEY => false
      }
    )
  end

  it "refuses a project rollback with an inspectable active-grant reason and preserves rollout state" do
    grant = create(:work_item_continuation_grant, project:, issue:, start_phase: "coding", endpoint: "merge")

    expect {
      FeatureFlags.disable!(:automation_phases, project:)
    }.to raise_error(described_class::ActiveGrantsError, /#{project.id}.*#{grant.id}/)

    expect(FeatureFlags.enabled?(:automation_phases, project:)).to be(true)
    expect(grant.reload).to be_active
  end

  it "permits actor-gate cleanup without inspecting grants when a tenant override keeps the project enabled" do
    create(:tenant_setting, account:, features: { "automation_phases" => true })
    grant = create(:work_item_continuation_grant, project:, issue:, start_phase: "coding", endpoint: "merge")

    FeatureFlags.disable!(:automation_phases, project:)

    expect(FeatureFlags.rollout_status(:automation_phases)[:actors]).not_to include(project.flipper_id)
    expect(FeatureFlags.enabled?(:automation_phases, project:)).to be(true)
    expect(grant.reload).to be_active
  end

  it "reconciles queued work after revocation before permitting rollback" do
    grant = create(:work_item_continuation_grant, project:, issue:, start_phase: "coding", endpoint: "merge")
    run = create(:agent_run, :queued, :automatic, project:, issue:, goal: "create_pr")
    disable_coding
    grant.revoke!

    FeatureFlags.disable!(:automation_phases, project:)

    expect(FeatureFlags.rollout_status(:automation_phases)[:actors]).not_to include(project.flipper_id)
    expect(run.reload.status).to eq("cancelled")
    expect(FeatureFlags.enabled?(:automation_phases, project:)).to be(false)
  end

  it "refuses rollback while a claimed queued run remains phase-unauthorized" do
    grant = create(:work_item_continuation_grant, project:, issue:, start_phase: "coding", endpoint: "merge")
    run = create(:agent_run, :queued, :automatic, :with_temporal, project:, issue:, goal: "create_pr")
    disable_coding
    grant.revoke!

    expect {
      FeatureFlags.disable!(:automation_phases, project:)
    }.to raise_error(described_class::PendingReconciliationError, /#{project.id}.*#{run.id}/)

    expect(run.reload.status).to eq("queued")
    expect(FeatureFlags.enabled?(:automation_phases, project:)).to be(true)
  end

  it "permits rollback after a finished grant without cancelling independently authorized work" do
    grant = create(:work_item_continuation_grant, project:, issue:, start_phase: "coding", endpoint: "merge")
    run = create(:agent_run, :queued, :automatic, project:, issue:, goal: "create_pr")
    grant.complete!

    FeatureFlags.disable!(:automation_phases, project:)

    expect(FeatureFlags.rollout_status(:automation_phases)[:actors]).not_to include(project.flipper_id)
    expect(run.reload.status).to eq("queued")
    expect(FeatureFlags.enabled?(:automation_phases, project:)).to be(false)
  end

  it "protects a tenant rollback without inspecting grants from another tenant" do
    other_project = create(:project)
    create(:tenant_setting, account:, features: { "automation_phases" => true })
    FeatureFlags.enable!(:automation_phases, project: other_project)
    create(:work_item_continuation_grant, project: other_project)

    FeatureFlags.with_tenant_rollback_protection(
      tenant_setting: account.tenant_setting,
      features: { "automation_phases" => false }
    ) do
      account.tenant_setting.update!(features: { "automation_phases" => false })
    end

    expect(FeatureFlags.enabled?(:automation_phases, project:)).to be(false)
    expect(FeatureFlags.enabled?(:automation_phases, project: other_project)).to be(true)
  end

  it "refuses a global rollback when any affected project has an active grant" do
    FeatureFlags.disable!(:automation_phases, project:)
    FeatureFlags.enable!(:automation_phases)
    grant = create(:work_item_continuation_grant, project:, issue:)

    expect {
      FeatureFlags.disable!(:automation_phases)
    }.to raise_error(described_class::ActiveGrantsError, /#{grant.id}/)

    expect(FeatureFlags.enabled?(:automation_phases, project:)).to be(true)
  end
end
