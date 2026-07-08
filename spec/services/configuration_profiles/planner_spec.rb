# frozen_string_literal: true

require "rails_helper"

RSpec.describe ConfigurationProfiles::Planner do
  let(:project) { create(:project) }

  describe ".for_profile" do
    it "produces a plan that moves the project to the profile" do
      plan = described_class.for_profile(project, ConfigurationProfiles::Registry.find(:solo_automated))

      expect(plan.source).to eq(:configuration_profile)
      expect(plan.reference).to eq(:solo_automated)
      expect(plan.changes.map(&:field)).to include(:auto_pick_enabled, :auto_merge_mode)
      expect(plan.changes.find { |c| c.field == :auto_pick_enabled }.to).to be true
    end

    it "omits fields that already match" do
      project.update!(auto_add_labels_enabled: true)
      plan = described_class.for_profile(project, ConfigurationProfiles::Registry.find(:solo_automated))

      expect(plan.applied_fields).not_to include(:auto_add_labels_enabled)
    end
  end

  describe ".for_values" do
    it "builds a plan from an arbitrary field hash" do
      plan = described_class.for_values(project, { "auto_pick_enabled" => true }, label: "custom", source: :cost_budget_preset)
      expect(plan.source).to eq(:cost_budget_preset)
      expect(plan.applied_fields).to eq(%i[auto_pick_enabled])
    end

    it "ignores unknown keys" do
      plan = described_class.for_values(project, { "not_a_field" => true }, label: "custom", source: :custom)
      expect(plan).to be_empty
    end
  end

  describe ".call dispatch" do
    it "routes a Profile to for_profile" do
      plan = described_class.call(project, ConfigurationProfiles::Registry.find(:observe_only))
      expect(plan.source).to eq(:configuration_profile)
    end

    it "routes a hash to for_values" do
      plan = described_class.call(project, { auto_pick_enabled: true }, label: "x", source: :custom)
      expect(plan.label).to eq("x")
    end
  end
end
