# frozen_string_literal: true

require "rails_helper"

# @spec AUTOMATION-PHASES-014
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

  it "blocks project rollback while a continuation grant remains active" do
    FeatureFlags.enable!(described_class::FLAG, project:)
    create(:work_item_continuation_grant, project:, issue: create(:issue, project:))

    expect {
      FeatureFlags.disable!(described_class::FLAG, project:)
    }.to raise_error(FeatureFlags::RollbackBlockedError, /active continuation grants/)

    expect(described_class.enabled?(project)).to be(true)
  end

  it "does not let another project's grant block this project's rollback" do
    other_project = create(:project)
    FeatureFlags.enable!(described_class::FLAG, project:)
    create(:work_item_continuation_grant, project: other_project, issue: create(:issue, project: other_project))

    FeatureFlags.disable!(described_class::FLAG, project:)

    expect(described_class.enabled?(project)).to be(false)
  end

  it "reads through FeatureFlags so tenant overrides still apply" do
    create(:tenant_setting, account:, features: { "automation_phases" => true })

    expect(described_class.enabled?(project)).to be(true)
  end

  it "batch-loads tenant overrides for a project collection" do
    create(:tenant_setting, account:, features: { "automation_phases" => true })
    projects = create_list(:project, 3, account:)

    queries = capture_queries { described_class.enabled_project_ids(projects.map(&:id)) }

    expect(queries.grep(/FROM \"accounts\"/).size).to eq(1)
    expect(queries.grep(/FROM \"tenant_settings\"/).size).to eq(1)
  end
end
