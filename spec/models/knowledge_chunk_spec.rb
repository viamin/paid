# frozen_string_literal: true

require "rails_helper"

RSpec.describe KnowledgeChunk do
  describe "associations" do
    it { is_expected.to belong_to(:knowledge_artifact) }
    it { is_expected.to belong_to(:project) }
    it { is_expected.to have_many(:outgoing_links).dependent(:destroy) }
    it { is_expected.to have_many(:incoming_links).dependent(:destroy) }
  end

  describe "validations" do
    it { is_expected.to validate_presence_of(:chunk_type) }
    it { is_expected.to validate_presence_of(:content) }
    it { is_expected.to validate_presence_of(:content_hash) }
    it { is_expected.to validate_presence_of(:status) }
    it { is_expected.to validate_inclusion_of(:status).in_array(KnowledgeChunk::STATUSES) }
  end
end
