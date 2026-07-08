# frozen_string_literal: true

require "rails_helper"

RSpec.describe Configuration::Profiles::SoloAutomated do
  it_behaves_like "a configuration profile"

  it "targets full execution with auto-pick and no review gate" do
    expect(described_class.targets).to include(
      "active" => true,
      "auto_pick_enabled" => true,
      "adoption_mode" => "full_execution",
      "review_enabled" => false
    )
  end

  it "has no prerequisites" do
    project = build(:project)
    expect(described_class.prerequisites_for(project, targets: described_class.targets)).to be_empty
  end
end
