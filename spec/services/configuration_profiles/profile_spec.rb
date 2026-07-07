# frozen_string_literal: true

require "rails_helper"

RSpec.describe ConfigurationProfiles::Profile do
  let(:field_keys) { ConfigurationProfiles::FieldSet.keys.map(&:to_s) }

  describe "construction" do
    it "stringifies and accepts full coverage" do
      values = field_keys.index_with { false }
      profile = described_class.new(key: :x, name: "X", description: "d", values: values)
      expect(profile.values.keys).to match_array(field_keys)
    end

    it "rejects missing fields and names the offending profile" do
      expect {
        described_class.new(key: :observe_only, name: "X", description: "d", values: { "auto_pick_enabled" => false })
      }.to raise_error(ArgumentError, /Profile :observe_only does not cover the operating-mode field set/)
    end

    it "rejects unknown fields and names the offending profile" do
      values = field_keys.index_with { false }.merge("bogus_field" => true)
      expect {
        described_class.new(key: :solo_automated, name: "X", description: "d", values: values)
      }.to raise_error(ArgumentError, /Profile :solo_automated does not cover.*Unknown fields/)
    end
  end

  describe "#diff_against / #matches?" do
    let(:profile) { ConfigurationProfiles::Registry.find(:observe_only) }

    it "returns no changes when the snapshot matches" do
      snapshot = profile.values.transform_keys(&:to_s)
      expect(profile.diff_against(snapshot)).to be_empty
      expect(profile.matches?(snapshot)).to be true
    end

    it "reports only the differing fields" do
      snapshot = profile.values.transform_keys(&:to_s).merge("auto_pick_enabled" => true)
      diff = profile.diff_against(snapshot)
      expect(diff.map(&:field)).to eq(%i[auto_pick_enabled])
      expect(diff.first.from).to be true
      expect(diff.first.to).to be false
    end
  end

  describe "#value_for" do
    it "returns the configured value for a field" do
      profile = ConfigurationProfiles::Registry.find(:solo_automated)
      expect(profile.value_for(:auto_pick_enabled)).to be true
    end
  end
end
