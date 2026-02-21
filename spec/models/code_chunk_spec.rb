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
    it { is_expected.to validate_inclusion_of(:chunk_type).in_array(CodeChunk::CHUNK_TYPES) }
  end

  describe "scopes" do
    describe ".for_project" do
      it "returns chunks for the given project" do
        project = create(:project)
        other_project = create(:project)
        chunk = create(:code_chunk, project: project)
        create(:code_chunk, project: other_project)

        expect(described_class.for_project(project)).to contain_exactly(chunk)
      end
    end

    describe ".by_file" do
      it "returns chunks for the given file path" do
        chunk = create(:code_chunk, file_path: "app/models/user.rb")
        create(:code_chunk, file_path: "app/models/project.rb")

        expect(described_class.by_file("app/models/user.rb")).to contain_exactly(chunk)
      end
    end
  end

  describe "content_hash computation" do
    it "computes content_hash before validation" do
      chunk = build(:code_chunk, content: "def hello; end", content_hash: nil)
      chunk.valid?

      expect(chunk.content_hash).to eq(Digest::SHA256.hexdigest("def hello; end"))
    end

    it "updates content_hash when content changes" do
      chunk = create(:code_chunk, content: "original")
      original_hash = chunk.content_hash

      chunk.content = "updated"
      chunk.valid?

      expect(chunk.content_hash).not_to eq(original_hash)
      expect(chunk.content_hash).to eq(Digest::SHA256.hexdigest("updated"))
    end
  end

  describe "#embedded?" do
    it "returns false when embedding is nil" do
      chunk = build(:code_chunk)
      expect(chunk.embedded?).to be false
    end

    it "returns true when embedding is present" do
      chunk = build(:code_chunk, :with_embedding)
      expect(chunk.embedded?).to be true
    end
  end

  describe "project association" do
    it "is destroyed when project is destroyed" do
      project = create(:project)
      create(:code_chunk, project: project)

      expect { project.destroy }.to change(described_class, :count).by(-1)
    end
  end
end
