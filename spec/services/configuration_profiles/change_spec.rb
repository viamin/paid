# frozen_string_literal: true

require "rails_helper"

RSpec.describe ConfigurationProfiles::Change do
  describe "#reverser" do
    it "swaps from and to" do
      change = described_class.new(field: :auto_pick_enabled, from: false, to: true)
      expect(change.reverser).to eq(described_class.new(field: :auto_pick_enabled, from: true, to: false))
    end
  end

  describe "#noop?" do
    it { expect(described_class.new(field: :x, from: true, to: true)).to be_noop }
    it { expect(described_class.new(field: :x, from: true, to: false)).not_to be_noop }
  end
end
