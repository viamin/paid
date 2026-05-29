# frozen_string_literal: true

require "rails_helper"

RSpec.describe MarketplaceEntry do
  describe "validations" do
    subject(:entry) { build(:marketplace_entry) }

    it { is_expected.to validate_presence_of(:name) }
    it { is_expected.to validate_inclusion_of(:entry_type).in_array(described_class::ENTRY_TYPES) }
    it { is_expected.to validate_inclusion_of(:team_scope).in_array(described_class::TEAM_SCOPES) }
    it { is_expected.to validate_inclusion_of(:status).in_array(described_class::STATUSES) }
    it { is_expected.to validate_inclusion_of(:certification_status).in_array(described_class::CERTIFICATION_STATUSES) }
    it { is_expected.to validate_inclusion_of(:support_tier).in_array(described_class::SUPPORT_TIERS) }
  end

  describe "#create_version!" do
    it "creates a sequential version and promotes it to current_version" do
      entry = create(:marketplace_entry, current_version: nil)

      version1 = entry.create_version!(canonical_artifact: { "content" => "v1" }, renderers: {}, compatibility_constraints: {}, review_metadata: {})
      version2 = entry.create_version!(canonical_artifact: { "content" => "v2" }, renderers: {}, compatibility_constraints: {}, review_metadata: {})

      expect(version1.version).to eq(1)
      expect(version2.version).to eq(2)
      expect(entry.reload.current_version).to eq(version2)
    end
  end

  describe "#tags_csv=" do
    it "normalizes comma separated tags" do
      entry = build(:marketplace_entry)
      entry.tags_csv = "rails, internal-api, rails"

      expect(entry.tags).to eq([ "rails", "internal-api" ])
    end
  end

  describe "extension points" do
    it "rejects unsupported extension points" do
      entry = build(:marketplace_entry, extension_points: [ "unsupported" ])

      expect(entry).not_to be_valid
      expect(entry.errors[:extension_points]).to include("contains unsupported values: unsupported")
    end
  end

  describe ".ransackable_associations" do
    it "does not expose account traversal" do
      expect(described_class.ransackable_associations).to eq([ "current_version" ])
    end
  end

  describe "#destroy" do
    it "prevents deleting entries that have been attached to agent runs" do
      entry = create(:marketplace_entry)
      version = create(:marketplace_entry_version, marketplace_entry: entry)
      entry.update!(current_version: version)
      agent_run = create(:agent_run, project: create(:project, account: entry.account))
      create(:agent_run_marketplace_entry,
        agent_run: agent_run,
        marketplace_entry: entry,
        marketplace_entry_version: version)

      expect(entry.destroy).to be(false)
      expect(entry.errors[:base]).to include("cannot delete marketplace entries that have been attached to agent runs")
      expect(described_class.exists?(entry.id)).to be(true)
      expect(MarketplaceEntryVersion.exists?(version.id)).to be(true)
    end
  end
end
