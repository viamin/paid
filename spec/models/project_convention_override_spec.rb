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
  end
end
