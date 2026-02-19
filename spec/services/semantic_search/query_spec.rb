# frozen_string_literal: true

require "rails_helper"

RSpec.describe SemanticSearch::Query do
  let(:project) { create(:project) }

  describe ".call" do
    context "with text search (no embeddings)" do
      before do
        create(:code_chunk, project: project, file_path: "app/models/user.rb",
               content: "class User\n  def authenticate(password)\n    BCrypt::Password.new(encrypted_password) == password\n  end\nend",
               language: "ruby")
        create(:code_chunk, project: project, file_path: "app/models/post.rb",
               content: "class Post\n  belongs_to :author\nend",
               language: "ruby")
        create(:code_chunk, project: project, file_path: "app/controllers/sessions_controller.rb",
               content: "class SessionsController\n  def create\n    user = User.authenticate(params[:password])\n  end\nend",
               language: "ruby")
      end

      it "finds chunks matching content keywords" do
        results = described_class.call(query: "authenticate", project: project)

        expect(results.map(&:file_path)).to include("app/models/user.rb")
        expect(results.map(&:file_path)).to include("app/controllers/sessions_controller.rb")
      end

      it "finds chunks matching file paths" do
        results = described_class.call(query: "sessions_controller", project: project)

        expect(results.map(&:file_path)).to include("app/controllers/sessions_controller.rb")
      end

      it "respects the limit parameter" do
        results = described_class.call(query: "class", project: project, limit: 2)

        expect(results.length).to eq(2)
      end

      it "returns empty when no matches found" do
        results = described_class.call(query: "zzzzqqqq", project: project)

        expect(results).to be_empty
      end

      it "does not return chunks from other projects" do
        other_project = create(:project)
        create(:code_chunk, project: other_project, file_path: "app/models/user.rb",
               content: "class User\n  def authenticate\n  end\nend")

        results = described_class.call(query: "authenticate", project: project)

        results.each do |chunk|
          expect(chunk.project_id).to eq(project.id)
        end
      end
    end

    context "with explicit text mode" do
      it "uses text search even when embeddings exist" do
        create(:code_chunk, project: project, content: "auth code here", language: "ruby")

        results = described_class.call(query: "auth", project: project, mode: :text)

        expect(results).not_to be_empty
      end
    end

    context "with blank query" do
      it "returns empty results" do
        create(:code_chunk, project: project, content: "some code")

        results = described_class.call(query: "", project: project)

        expect(results).to be_empty
      end
    end

    context "with no indexed chunks" do
      it "returns empty results" do
        results = described_class.call(query: "anything", project: project)

        expect(results).to be_empty
      end
    end
  end
end
