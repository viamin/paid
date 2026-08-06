# frozen_string_literal: true

require "rails_helper"

RSpec.describe Configuration::Profiles::ManualOnLabel do
  it_behaves_like "a configuration profile"

  it "targets advisory execution driven by label only" do
    expect(described_class.targets).to include(
      "auto_pick_enabled" => false,
      "auto_scan_prs" => true,
      "automation_on_label_enabled" => true,
      "adoption_mode" => "advisory"
    )
  end
end
