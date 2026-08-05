# frozen_string_literal: true

require "rails_helper"

RSpec.describe Configuration::Profiles::TeamReviewed do
  it_behaves_like "a configuration profile"

  it "targets the reviewed operating-mode field set" do
    expect(described_class.targets).to include(
      "auto_pick_enabled" => true,
      "auto_enhance_enabled" => true,
      "adoption_mode" => "review_only",
      "quality_gate_enabled" => true
    )
  end

  it "requires an owner reviewer login override" do
    project = build(:project)
    prerequisites = described_class.prerequisites_for(project, targets: described_class.targets)
    expect(prerequisites).to include(a_string_matching(/owner_reviewer_login/i))
  end

  it "lists the owner_reviewer_login clarifying question" do
    expect(described_class.override_keys).to eq(%w[owner_reviewer_login])
  end

  context "when a reviewer is supplied" do
    it "has no prerequisites" do
      project = build(:project)
      targets = described_class.targets.merge("owner_reviewer_login" => "octocat")
      expect(described_class.prerequisites_for(project, targets: targets)).to be_empty
    end
  end
end
