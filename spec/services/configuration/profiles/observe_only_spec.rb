# frozen_string_literal: true

require "rails_helper"

RSpec.describe Configuration::Profiles::ObserveOnly do
  it_behaves_like "a configuration profile"

  it "targets observe-only adoption with automation disabled" do
    expect(described_class.targets).to include(
      "adoption_mode" => "observe_only",
      "auto_pick_enabled" => false,
      "automation_on_label_enabled" => false,
      "auto_merge_mode" => "off"
    )
  end
end
