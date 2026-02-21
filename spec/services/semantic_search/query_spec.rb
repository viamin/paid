# frozen_string_literal: true

require "rails_helper"

RSpec.describe SemanticSearch::Query do
  let(:project) { create(:project) }

  describe ".call" do
    it "raises ArgumentError for unknown mode" do
      expect {
        described_class.call(query: "test", project: project, mode: :invalid)
      }.to raise_error(ArgumentError, /Unknown search mode/)
    end

    it "raises ArgumentError for semantic mode without embedding" do
      expect {
        described_class.call(query: "test", project: project, mode: :semantic)
      }.to raise_error(ArgumentError, /requires an embedding vector/)
    end

    context "with text search" do
      before do
        create(:code_chunk, project: project, content: "def authenticate_user\n  session[:user_id]\nend", identifier: "authenticate_user")
        create(:code_chunk, project: project, content: "def calculate_total\n  items.sum(:price)\nend", identifier: "calculate_total")
        create(:code_chunk, project: project, content: "class UserController\n  def show\n  end\nend", identifier: "UserController", chunk_type: "class")
      end

      it "finds chunks matching query terms" do
        results = described_class.call(query: "authenticate", project: project, mode: :text)

        expect(results.map(&:identifier)).to include("authenticate_user")
      end

      it "does not return unrelated chunks" do
        results = described_class.call(query: "authenticate", project: project, mode: :text)

        expect(results.map(&:identifier)).not_to include("calculate_total")
      end

      it "searches case-insensitively" do
        results = described_class.call(query: "AUTHENTICATE", project: project, mode: :text)

        expect(results.map(&:identifier)).to include("authenticate_user")
      end

      it "respects the limit parameter" do
        results = described_class.call(query: "def", project: project, mode: :text, limit: 1)

        expect(results.count).to eq(1)
      end

      it "returns empty for blank query terms" do
        results = described_class.call(query: "   ", project: project, mode: :text)

        expect(results).to be_empty
      end

      it "scopes results to the given project" do
        other_project = create(:project)
        create(:code_chunk, project: other_project, content: "def authenticate_user; end", identifier: "authenticate_user")

        results = described_class.call(query: "authenticate", project: project, mode: :text)

        expect(results.count).to eq(1)
      end
    end

    context "with hybrid search without embedding" do
      before do
        create(:code_chunk, project: project, content: "def search_users; end", identifier: "search_users")
      end

      it "falls back to text search when no embedding provided" do
        results = described_class.call(query: "search", project: project, mode: :hybrid)

        expect(results.map(&:identifier)).to include("search_users")
      end
    end
  end
end
