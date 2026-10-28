# frozen_string_literal: true

require "rails_helper"

# @spec AUTOMATION-PHASES-014 @spec AUTOMATION-PHASES-015
RSpec.describe Automation::RolloutGuard do
  let(:account) { create(:account) }
  let(:project) { create(:project, account:) }

  it "defines the rollout flag default-off" do
    definition = FeatureFlags.definition(described_class::FLAG)

    expect(definition.name).to eq(:automation_phases)
    expect(definition.rollout_plan).to include("Default-off")
  end

  it "is off for a project that never opted in" do
    expect(described_class.enabled?(project)).to be(false)
  end

  it "is on for a project that opted in" do
    FeatureFlags.enable!(described_class::FLAG, project:)

    expect(described_class.enabled?(project)).to be(true)
  end

  it "reads through FeatureFlags so tenant overrides still apply" do
    create(:tenant_setting, account:, features: { "automation_phases" => true })

    expect(described_class.enabled?(project)).to be(true)
  end

  it "blocks rollback while the project has an active continuation grant" do
    issue = create(:issue, project:)
    create(:work_item_continuation_grant, project:, issue:, start_phase: "coding", endpoint: "merge")
    FeatureFlags.enable!(:automation_phases, project:)

    expect {
      FeatureFlags.disable!(:automation_phases, project:)
    }.to raise_error(described_class::RollbackBlocked, /complete or revoke/)

    expect(described_class.enabled?(project)).to be(true)
  end

  it "allows rollback after every continuation grant is closed" do
    issue = create(:issue, project:)
    grant = create(:work_item_continuation_grant, project:, issue:, start_phase: "coding", endpoint: "merge")
    FeatureFlags.enable!(:automation_phases, project:)
    grant.revoke!

    FeatureFlags.disable!(:automation_phases, project:)

    expect(described_class.enabled?(project)).to be(false)
  end

  it "batch-loads tenant overrides for a project collection" do
    create(:tenant_setting, account:, features: { "automation_phases" => true })
    projects = create_list(:project, 3, account:)

    queries = capture_queries { described_class.enabled_project_ids(projects.map(&:id)) }

    expect(queries.grep(/FROM \"accounts\"/).size).to eq(1)
    expect(queries.grep(/FROM \"tenant_settings\"/).size).to eq(1)
  end
end
