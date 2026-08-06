# frozen_string_literal: true

require "rails_helper"

RSpec.describe Configuration::Profiles::SoloAutomated do
  it_behaves_like "a configuration profile"

  it "targets the high-autonomy operating-mode field set" do
    expect(described_class.targets).to include(
      "auto_pick_enabled" => true,
      "auto_merge_mode" => "all",
      "auto_release_granularity" => "all",
      "adoption_mode" => "full_execution",
      "review_paid_agent" => true
    )
  end

  it "requires the paid review bot when paid-agent review stays enabled" do
    allow(Github::ReviewBotInstallationToken).to receive(:configured?).and_return(false)

    project = build(:project)
    expect(described_class.prerequisites_for(project, targets: described_class.targets))
      .to include(a_string_matching(/review bot/i))
  end
end
