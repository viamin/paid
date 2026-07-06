# frozen_string_literal: true

require "rails_helper"

RSpec.describe ConfigurationProfiles::FieldSet do
  describe ".keys" do
    it "returns the canonical operating-mode field list" do
      expect(described_class.keys).to include(:auto_pick_enabled, :auto_merge_mode, :adoption_mode,
                                              :review_paid_agent, :quality_gate_enabled)
    end
  end

  describe ".lookup" do
    it "returns the field definition" do
      field = described_class.lookup(:auto_merge_mode)
      expect(field.kind).to eq(:enum_attribute)
      expect(field.options).to eq(%w[off dependabot_only all])
    end

    it "raises for unknown fields" do
      expect { described_class.lookup(:nope) }.to raise_error(ArgumentError, /Unknown configuration profile field/)
    end
  end

  describe ".attribute_columns" do
    it "excludes nested-setting fields (adoption_mode, review_method, quality_gate)" do
      expect(described_class.attribute_columns).not_to include("adoption_mode")
      expect(described_class.attribute_columns).to include("auto_pick_enabled", "merge_method")
    end
  end

  describe ".read / .write" do
    let(:project) { create(:project) }

    before do
      # Enabling paid-agent review normally requires the paid-code-reviewer
      # GitHub App credential; treat that as an external dependency in specs.
      allow(Github::ReviewBotInstallationToken).to receive(:configured?).and_return(true)
    end

    it "round-trips a boolean attribute" do
      described_class.write(project, :auto_pick_enabled, true)
      project.save!
      expect(described_class.read(project.reload, :auto_pick_enabled)).to be true
    end

    it "round-trips an enum attribute" do
      described_class.write(project, :auto_merge_mode, "all")
      project.save!
      expect(described_class.read(project.reload, :auto_merge_mode)).to eq("all")
    end

    it "round-trips the adoption_mode interop setting" do
      described_class.write(project, :adoption_mode, "full_execution")
      project.save!
      expect(described_class.read(project.reload, :adoption_mode)).to eq("full_execution")
    end

    it "round-trips a review method enabled flag" do
      described_class.write(project, :review_paid_agent, true)
      project.save!
      expect(described_class.read(project.reload, :review_paid_agent)).to be true
    end

    it "round-trips the quality gate flag" do
      described_class.write(project, :quality_gate_enabled, true)
      project.save!
      expect(described_class.read(project.reload, :quality_gate_enabled)).to be true
    end

    it "coerces stringy booleans on write" do
      described_class.write(project, :auto_pick_enabled, "true")
      expect(project.auto_pick_enabled).to be true
    end
  end

  describe ".snapshot" do
    it "reads every field into a string-keyed hash" do
      project = create(:project, auto_pick_enabled: true)
      snapshot = described_class.snapshot(project)

      expect(snapshot.keys).to match_array(described_class.keys.map(&:to_s))
      expect(snapshot["auto_pick_enabled"]).to be true
      expect(snapshot["adoption_mode"]).to eq("observe_only")
    end
  end

  describe ".equivalent?" do
      it { expect(described_class.equivalent?(true, "true")).to be true }
      it { expect(described_class.equivalent?(false, "false")).to be true }
      it { expect(described_class.equivalent?("off", "off")).to be true }
      it { expect(described_class.equivalent?(true, false)).to be false }
  end
end
