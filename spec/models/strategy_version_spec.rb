# frozen_string_literal: true

require "rails_helper"

RSpec.describe StrategyVersion do
  describe "associations" do
    it { is_expected.to belong_to(:strategy) }
    it { is_expected.to belong_to(:created_by_user).class_name("User").optional }
    it { is_expected.to belong_to(:parent_version).class_name("StrategyVersion").optional }
    it { is_expected.to belong_to(:promoted_by_user).class_name("User").optional }
    it { is_expected.to have_many(:child_versions).class_name("StrategyVersion").with_foreign_key(:parent_version_id).dependent(:nullify) }

    it "has many orchestration_decisions when the FK column exists" do
      skip "strategy_version_id column not present" unless ActiveRecord::Base.connection.column_exists?(:orchestration_decisions, :strategy_version_id)
      expect(described_class.reflect_on_association(:orchestration_decisions)).to have_attributes(
        macro: :has_many,
        options: include(dependent: :nullify)
      )
    end
  end

  describe "validations" do
    subject { build(:strategy_version) }

    it { is_expected.to validate_presence_of(:version) }
    it { is_expected.to validate_numericality_of(:version).only_integer.is_greater_than(0) }
    it { is_expected.to validate_inclusion_of(:promotion_state).in_array(described_class::PROMOTION_STATES) }

    it "validates version uniqueness within strategy" do
      strategy = create(:strategy, :global)
      create(:strategy_version, strategy: strategy, version: 1)

      duplicate = build(:strategy_version, strategy: strategy, version: 1)
      expect(duplicate).not_to be_valid
      expect(duplicate.errors[:version]).to be_present
    end

    it "requires content to be an object" do
      version = build(:strategy_version, content: [])

      expect(version).not_to be_valid
      expect(version.errors[:content]).to include("must be an object")
    end

    it "requires provenance to be an object" do
      version = build(:strategy_version, provenance: [])

      expect(version).not_to be_valid
      expect(version.errors[:provenance]).to include("must be an object")
    end

    it "requires parent version to belong to the same strategy" do
      version = build(:strategy_version)
      version.parent_version = create(:strategy_version)

      expect(version).not_to be_valid
      expect(version.errors[:parent_version]).to include("must belong to the same strategy")
    end

    it "allows only one active version per strategy" do
      strategy = create(:strategy, :global)
      create(:strategy_version, :active, strategy: strategy)

      duplicate_active = build(:strategy_version, :active, strategy: strategy)

      expect(duplicate_active).not_to be_valid
      expect(duplicate_active.errors[:promotion_state]).to include("allows only one active version per strategy")
    end

    it "allows a new active version after the previous one is retired" do
      strategy = create(:strategy, :global)
      create(:strategy_version, :retired, strategy: strategy, version: 1)

      replacement = build(:strategy_version, :active, strategy: strategy, version: 2)

      expect(replacement).to be_valid
    end
  end

  describe "immutability" do
    it "prevents content field updates after creation" do
      version = create(:strategy_version)

      version.content = { "mode" => "updated" }
      expect(version).not_to be_valid
      expect(version.errors[:base]).to include("strategy version content fields are immutable after creation")
    end

    it "allows promotion field updates after creation" do
      version = create(:strategy_version)

      version.promotion_state = "candidate"
      expect(version).to be_valid
    end
  end

  describe "promotion state" do
    it "#active? is true when the version is active and not retired" do
      version = create(:strategy_version, :active)

      expect(version).to be_active
      expect(version).not_to be_retired
    end

    it "#retired? is true when retired_at is set" do
      version = create(:strategy_version, :retired)

      expect(version).to be_retired
      expect(version).not_to be_active
    end

    it "active/retired scopes partition versions by promotion state" do
      active = create(:strategy_version, :active)
      retired = create(:strategy_version, :retired)

      expect(described_class.active).to include(active)
      expect(described_class.active).not_to include(retired)
      expect(described_class.retired).to include(retired)
      expect(described_class.retired).not_to include(active)
    end
  end
end
