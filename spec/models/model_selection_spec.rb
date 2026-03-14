# frozen_string_literal: true

require "rails_helper"

RSpec.describe ModelSelection do
  describe "validations" do
    subject { build(:model_selection) }

    it { is_expected.to validate_presence_of(:selector_type) }
    it { is_expected.to validate_inclusion_of(:selector_type).in_array(described_class::SELECTOR_TYPES) }
    it { is_expected.to validate_uniqueness_of(:agent_run_id) }
  end

  describe "associations" do
    it { is_expected.to belong_to(:agent_run) }
    it { is_expected.to belong_to(:llm_model) }
  end
end
