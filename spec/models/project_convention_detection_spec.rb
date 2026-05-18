# frozen_string_literal: true

require "rails_helper"

RSpec.describe ProjectConventionDetection do
  describe "associations" do
    it { is_expected.to belong_to(:project) }
    it { is_expected.to belong_to(:project_version) }
  end

  describe "validations" do
    subject(:detection) { build(:project_convention_detection) }

    it { is_expected.to validate_presence_of(:key) }
    it { is_expected.to validate_presence_of(:detector_key) }
    it { is_expected.to validate_presence_of(:detected_at) }
    it { is_expected.to validate_numericality_of(:confidence).is_greater_than_or_equal_to(0).is_less_than_or_equal_to(1) }
  end

  it "rejects a project that does not match the project version" do
    detection = build(:project_convention_detection)
    detection.project = create(:project)

    expect(detection).not_to be_valid
    expect(detection.errors[:project]).to include("must match the project version's project")
  end
end
