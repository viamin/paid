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

  it "reads through FeatureFlags so tenant overrides still apply" do
    create(:tenant_setting, account:, features: { "automation_phases" => true })

    expect(described_class.enabled?(project)).to be(true)
  end
end
