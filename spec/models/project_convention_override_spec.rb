# frozen_string_literal: true

require "rails_helper"

RSpec.describe ProjectConventionOverride do
  describe "associations" do
    it { is_expected.to belong_to(:project) }
  end

  describe "validations" do
    subject(:override) { build(:project_convention_override) }

    it { is_expected.to validate_presence_of(:key) }
    it { is_expected.to validate_uniqueness_of(:key).scoped_to(:project_id) }
    it { is_expected.to validate_inclusion_of(:mode).in_array(described_class::MODES) }
  end

  it "maps legacy disabled overrides to ignore mode" do
    override = build(:project_convention_override, mode: nil, enabled: false)

    override.validate

    expect(override.mode).to eq("ignore")
    expect(override.enabled).to be(false)
  end

  it "requires a category when no convention key is available to derive one" do
    override = build(:project_convention_override, key: nil, category: nil)

    expect(override).not_to be_valid
    expect(override.errors[:category]).to include("can't be blank")
  end
end
