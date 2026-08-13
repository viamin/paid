# frozen_string_literal: true

require "rails_helper"

RSpec.describe Configuration::Profiles::QualityStrict do
  it_behaves_like "a configuration profile"

  it "targets the strict-quality operating mode" do
    expect(described_class.targets).to include(
      "auto_pick_enabled" => true,
      "auto_merge_mode" => "off",
      "review_paid_agent" => true,
      "quality_gate_enabled" => true
    )
  end

  it "requires the paid review bot when paid-agent review stays enabled" do
    allow(Github::ReviewBotInstallationToken).to receive(:configured?).and_return(false)

    prerequisites = described_class.prerequisites_for(build(:project), targets: described_class.targets)

    expect(prerequisites).to include(a_string_matching(/review bot/i))
  end
end
