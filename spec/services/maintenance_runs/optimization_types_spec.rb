# frozen_string_literal: true

require "rails_helper"

RSpec.describe MaintenanceRuns::OptimizationTypes do
  # @spec MAINT-OPT-001 MAINT-OPT-002 MAINT-OPT-003
  it "defines the curated optimization menu with catalog metadata" do
    expect(described_class.entries.map(&:key)).to eq(%w[
      performance
      design_architecture
      code_duplication
      security_hardening
      cost_resource_efficiency
      maintainability_readability
      test_coverage_quality
    ])

    expect(described_class.entries).to all(have_attributes(
        name: a_kind_of(String),
        investigation_description: a_kind_of(String),
        metric_hints: a_kind_of(Array),
        recipe_key: nil,
        repair_standing: a_kind_of(String)
      ))
  end

  # @spec MAINT-OPT-006
  it "does not resolve an unmapped selection" do
    expect(described_class.fetch("future_type")).to be_nil
  end
end
