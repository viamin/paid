# frozen_string_literal: true

require "rails_helper"

RSpec.describe Configuration::Profiles::ManualOnLabel do
  it_behaves_like "a configuration profile"

  it "targets full execution driven by label only" do
    expect(described_class.targets).to include(
      "active" => true,
      "auto_pick_enabled" => false,
      "automation_on_label_enabled" => true,
      "adoption_mode" => "full_execution"
    )
  end
end
