# frozen_string_literal: true

require "rails_helper"

RSpec.describe KnowledgeLink do
  describe "associations" do
    it { is_expected.to belong_to(:source_chunk).class_name("KnowledgeChunk") }
    it { is_expected.to belong_to(:target_chunk).class_name("KnowledgeChunk") }
  end

  describe "validations" do
    subject { build(:knowledge_link) }

    it { is_expected.to validate_presence_of(:link_type) }
    it { is_expected.to validate_inclusion_of(:link_type).in_array(described_class::LINK_TYPES) }

    it "validates uniqueness of source_chunk_id scoped to target_chunk_id and link_type" do
      existing = create(:knowledge_link)
      duplicate = build(:knowledge_link,
        source_chunk: existing.source_chunk,
        target_chunk: existing.target_chunk,
        link_type: existing.link_type)
      expect(duplicate).not_to be_valid
      expect(duplicate.errors[:source_chunk_id]).to include("has already been taken")
    end

    it { is_expected.to validate_numericality_of(:weight).is_greater_than_or_equal_to(0) }
  end
end
