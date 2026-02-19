# frozen_string_literal: true

require "rails_helper"

RSpec.describe CodeChunk do
  describe "associations" do
    it { is_expected.to belong_to(:project) }
  end

  describe "validations" do
    it { is_expected.to validate_presence_of(:file_path) }
    it { is_expected.to validate_presence_of(:chunk_type) }
    it { is_expected.to validate_presence_of(:content) }
    it { is_expected.to validate_inclusion_of(:chunk_type).in_array(described_class::CHUNK_TYPES) }
  end

  describe "content_hash computation" do
    it "computes content_hash before validation" do
      chunk = build(:code_chunk, content: "hello world", content_hash: nil)
      chunk.valid?
      expect(chunk.content_hash).to eq(Digest::SHA256.hexdigest("hello world"))
    end

    it "updates content_hash when content changes" do
      chunk = create(:code_chunk, content: "original")
      original_hash = chunk.content_hash

      chunk.content = "modified"
      chunk.valid?

      expect(chunk.content_hash).not_to eq(original_hash)
      expect(chunk.content_hash).to eq(Digest::SHA256.hexdigest("modified"))
    end
  end

  describe "scopes" do
    describe ".for_language" do
      it "filters by language" do
        ruby_chunk = create(:code_chunk, language: "ruby")
        create(:code_chunk, :javascript)

        expect(described_class.for_language("ruby")).to contain_exactly(ruby_chunk)
      end
    end

    describe ".for_chunk_type" do
      it "filters by chunk type" do
        file_chunk = create(:code_chunk, chunk_type: "file")
        create(:code_chunk, :with_identifier)

        expect(described_class.for_chunk_type("file")).to contain_exactly(file_chunk)
      end
    end
  end

  describe "#embedded?" do
    it "returns false when embedding is nil" do
      chunk = build(:code_chunk, embedding: nil)
      expect(chunk.embedded?).to be false
    end
  end

  describe "#stale?" do
    it "returns true when content has changed" do
      chunk = create(:code_chunk, content: "original")
      expect(chunk.stale?("modified")).to be true
    end

    it "returns false when content is unchanged" do
      content = "unchanged content"
      chunk = create(:code_chunk, content: content)
      expect(chunk.stale?(content)).to be false
    end
  end
end
