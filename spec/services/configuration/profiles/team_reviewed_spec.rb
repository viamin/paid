# frozen_string_literal: true

require "rails_helper"

RSpec.describe Configuration::Profiles::TeamReviewed do
  it_behaves_like "a configuration profile"

  it "targets review-only adoption without auto-pick" do
    expect(described_class.targets).to include(
      "active" => true,
      "auto_pick_enabled" => false,
      "adoption_mode" => "review_only",
      "review_enabled" => true
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

  context "when the review bot is configured and a reviewer is supplied" do
    it "has no prerequisites" do
      allow(Github::ReviewBotInstallationToken).to receive(:configured?).and_return(true)
      project = build(:project)
      targets = described_class.targets.merge("owner_reviewer_login" => "octocat")
      expect(described_class.prerequisites_for(project, targets: targets)).to be_empty
    end

    it "flags a missing review bot configuration" do
      allow(Github::ReviewBotInstallationToken).to receive(:configured?).and_return(false)
      project = build(:project)
      targets = described_class.targets.merge("owner_reviewer_login" => "octocat")
      expect(described_class.prerequisites_for(project, targets: targets))
        .to include(a_string_matching(/review bot/i))
    end
  end
end
