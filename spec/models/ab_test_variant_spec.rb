# frozen_string_literal: true

require "rails_helper"

RSpec.describe AbTestVariant do
  describe "validations" do
    subject { build(:ab_test_variant) }

    it { is_expected.to validate_presence_of(:name) }
    it { is_expected.to validate_uniqueness_of(:name).scoped_to(:ab_test_id) }
  end

  describe "associations" do
    it { is_expected.to belong_to(:ab_test) }
    it { is_expected.to belong_to(:prompt_version) }
  end
end
