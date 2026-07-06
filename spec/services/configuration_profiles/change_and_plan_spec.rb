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

RSpec.describe ConfigurationProfiles::Plan do
  let(:changes) do
    [
      ConfigurationProfiles::Change.new(field: :auto_pick_enabled, from: false, to: true),
      { field: :auto_merge_mode, from: "off", to: "all" }
    ]
  end
  let(:plan) { described_class.new(label: "Test", source: :custom, changes: changes) }

  it "coerces hash entries into Change objects" do
    expect(plan.changes).to all(be_a(ConfigurationProfiles::Change))
    expect(plan.changes.last.field).to eq(:auto_merge_mode)
  end

  it { expect(plan.size).to eq(2) }
  it { expect(plan).not_to be_empty }

  describe "#reverser" do
    it "reverses every change and relabels" do
      reversed = plan.reverser
      expect(reversed.changes.map(&:to)).to contain_exactly(false, "off")
      expect(reversed.label).to start_with("Revert")
    end
  end

  describe "#applied_fields" do
    it { expect(plan.applied_fields).to eq(%i[auto_pick_enabled auto_merge_mode]) }
  end

  it "is empty when there are no changes" do
    expect(described_class.new(label: "x", source: :custom, changes: [])).to be_empty
  end
end
