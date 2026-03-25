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
    it { is_expected.to validate_uniqueness_of(:source_chunk_id).ignoring_case_sensitivity.scoped_to([ :target_chunk_id, :link_type ]) }
  end
end
