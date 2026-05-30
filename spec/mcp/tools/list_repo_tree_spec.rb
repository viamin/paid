# frozen_string_literal: true

require "rails_helper"

RSpec.describe Tools::ListRepoTree do
  let(:account) { create(:account) }
  let(:user) { create(:user, :member, account: account) }
  let(:session) { create(:chat_session, account: account, created_by: user) }
  let(:tool) { described_class.new(user: user, session: session) }
  let(:project) { create(:project, account: account) }
  let(:github_client) { instance_double(GithubClient) }

  before do
    allow(GithubClient).to receive(:new).and_return(github_client)
    allow(github_client).to receive(:tree)
    allow(github_client).to receive(:contents)
  end

  describe "#call" do
    it "returns root tree entries" do
      tree_result = Struct.new(:tree).new([
        Struct.new(:path, :type, :size).new("README.md", "blob", 100),
        Struct.new(:path, :type, :size).new("app", "tree", 0),
        Struct.new(:path, :type, :size).new("app/models/foo.rb", "blob", 200)
      ])
      allow(github_client).to receive(:tree).and_return(tree_result)

      result = tool.call(project_id: project.id)

      expect(result[:entries].size).to eq(3)
      expect(result[:entries].first[:path]).to eq("README.md")
      expect(result[:identity]).to include("project-token")
    end

    it "returns directory entries for a specific path" do
      dir_entries = [
        Struct.new(:name, :path, :type, :size).new("foo.rb", "app/models/foo.rb", "file", 200),
        Struct.new(:name, :path, :type, :size).new("bar.rb", "app/models/bar.rb", "file", 300)
      ]
      allow(github_client).to receive(:contents).and_return(dir_entries)

      result = tool.call(project_id: project.id, path: "app/models")

      expect(result[:entries].size).to eq(2)
      expect(result[:path]).to eq("app/models")
    end

    it "returns error for not-found path" do
      allow(github_client).to receive(:contents).and_raise(GithubClient::NotFoundError, "Not found")

      result = tool.call(project_id: project.id, path: "nonexistent")

      expect(result[:error]).to include("not found")
    end

    it "raises for project in another account" do
      other_project = create(:project)

      expect { tool.call(project_id: other_project.id) }
        .to raise_error(ActiveRecord::RecordNotFound)
    end
  end
end
