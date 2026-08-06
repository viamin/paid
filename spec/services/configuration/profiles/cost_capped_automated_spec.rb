# frozen_string_literal: true

require "rails_helper"

RSpec.describe Configuration::Profiles::CostCappedAutomated do
  it_behaves_like "a configuration profile"

  it "targets the cost-capped operating mode" do
    expect(described_class.targets).to include(
      "auto_pick_enabled" => true,
      "auto_merge_mode" => "dependabot_only",
      "auto_release_granularity" => "off",
      "knowledge_evolution_enabled" => false
    )
  end
end
