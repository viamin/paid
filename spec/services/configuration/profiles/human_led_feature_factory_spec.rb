# frozen_string_literal: true

require "rails_helper"

RSpec.describe Configuration::Profiles::HumanLedFeatureFactory do
  it_behaves_like "a configuration profile"

  # @spec FEATURE-APPROVAL-002
  it "enables the human-led mode, suggests non-strict TDD, and leaves auto-merge off" do
    expect(described_class.targets).to include(
      "operating_mode" => "human_led_feature_factory",
      "tdd_mode" => "non_strict",
      "auto_merge_mode" => "off"
    )
  end

  # @spec FEATURE-APPROVAL-003
  it "offers auto-merge and TDD posture as explicit operator choices" do
    ids = described_class.clarifying_questions.map { |question| question[:id] }

    expect(ids).to include("auto_merge_mode", "tdd_mode")
  end

  # @spec FEATURE-APPROVAL-003
  it "applies operator selections instead of the suggested defaults" do
    project = create(:project)
    actor = create(:user, :owner, account: project.account)
    plan = Configuration::Profiles::Planner.call(
      profile: described_class, project: project, actor: actor,
      overrides: { "auto_merge_mode" => "all", "tdd_mode" => "strict" }
    )
    Configuration::Profiles::Applier.call(plan: plan, project: project, actor: actor)

    expect(project.reload.operating_mode).to eq("human_led_feature_factory")
    expect(project.tdd_mode).to eq("strict")
    expect(project.auto_merge_mode).to eq("all")
  end

  # @spec FEATURE-APPROVAL-002
  it "applies the suggested posture to a fresh project without prerequisites" do
    project = create(:project)
    actor = create(:user, :owner, account: project.account)
    plan = Configuration::Profiles::Planner.call(
      profile: described_class, project: project, actor: actor
    )

    expect(plan).not_to be_blocked
    expect(plan.changes.map(&:key)).to include("operating_mode", "tdd_mode", "auto_merge_mode")
  end
end
