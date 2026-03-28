# frozen_string_literal: true

require "rails_helper"

RSpec.describe DecisionRecordLink do
  subject(:link) { build(:decision_record_link) }

  describe "associations" do
    it { is_expected.to belong_to(:decision_record) }
  end

  describe "validations" do
    it { is_expected.to validate_presence_of(:linkable_type) }
    it { is_expected.to validate_length_of(:linkable_type).is_at_most(100) }
    it { is_expected.to validate_inclusion_of(:linkable_type).in_array(described_class::LINKABLE_TYPES) }
    it { is_expected.to validate_presence_of(:linkable_id) }
    it { is_expected.to validate_length_of(:linkable_id).is_at_most(100) }
    it { is_expected.to validate_presence_of(:link_type) }
    it { is_expected.to validate_length_of(:link_type).is_at_most(50) }
    it { is_expected.to validate_inclusion_of(:link_type).in_array(described_class::LINK_TYPES) }
  end
end
