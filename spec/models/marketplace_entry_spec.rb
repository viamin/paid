# frozen_string_literal: true

require "rails_helper"

RSpec.describe MarketplaceEntry do
  describe "validations" do
    subject(:entry) { build(:marketplace_entry) }

    it { is_expected.to validate_presence_of(:name) }
    it { is_expected.to validate_inclusion_of(:entry_type).in_array(described_class::PROMPT_COMPATIBLE_ENTRY_TYPES) }
    it { is_expected.to validate_inclusion_of(:team_scope).in_array(described_class::TEAM_SCOPES) }
    it { is_expected.to validate_inclusion_of(:status).in_array(described_class::STATUSES) }
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
end
