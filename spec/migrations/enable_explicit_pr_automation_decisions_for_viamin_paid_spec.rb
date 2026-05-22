# frozen_string_literal: true

require "rails_helper"
require Rails.root.join("db/migrate/20260416173627_enable_explicit_pr_automation_decisions_for_viamin_paid")

RSpec.describe EnableExplicitPrAutomationDecisionsForViaminPaid do
  let(:migration) { described_class.new }
  let(:test_definition) do
    FeatureFlags::Definition.new(
      name: :explicit_pr_automation_decisions,
      owner: "infrastructure",
      intent: "Test",
      rollout_plan: "None",
      cleanup_criteria: "None"
    )
  end

  before do
    FeatureFlags.flipper.features.each(&:remove)
    stub_const("#{FeatureFlags}::DEFINITIONS", {
      explicit_pr_automation_decisions: test_definition
    }.freeze)
  end

  it "enables explicit_pr_automation_decisions for the viamin/paid project" do
    viamin_paid = create(:project, owner: "viamin", repo: "paid")
    other_project = create(:project, owner: "other", repo: "repo")

    migration.up

    expect(FeatureFlags.enabled?(:explicit_pr_automation_decisions, project: viamin_paid)).to be(true)
    expect(FeatureFlags.enabled?(:explicit_pr_automation_decisions, project: other_project)).to be(false)
  end

  it "is a no-op when the viamin/paid project is absent" do
    create(:project, owner: "other", repo: "repo")

    expect { migration.up }.not_to raise_error
    expect(FeatureFlags.enabled?(:explicit_pr_automation_decisions)).to be(false)
  end

  it "is idempotent on repeated up runs" do
    viamin_paid = create(:project, owner: "viamin", repo: "paid")

    migration.up
    migration.up

    expect(FeatureFlags.enabled?(:explicit_pr_automation_decisions, project: viamin_paid)).to be(true)
  end

  it "reverses enablement on down" do
    viamin_paid = create(:project, owner: "viamin", repo: "paid")

    migration.up
    expect(FeatureFlags.enabled?(:explicit_pr_automation_decisions, project: viamin_paid)).to be(true)

    migration.down
    expect(FeatureFlags.enabled?(:explicit_pr_automation_decisions, project: viamin_paid)).to be(false)
  end
end
